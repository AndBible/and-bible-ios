import Foundation
import XCTest
@testable import BibleCore
import SwordKit

/** Payload-free installed-registry notification boundaries for My Documents changes. */
final class MyDocumentRegistrationPublicationTests: XCTestCase {
    /** Page-only edits stay quiet, while colliding-owner order changes wake registry consumers. */
    func testOnlyRegistrationAffectingSnapshotChangesPublish() {
        let firstID = UUID()
        let secondID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let documents = [
            document(id: firstID, name: "Owner", initials: "COLLIDE", order: 0, createdAt: createdAt),
            document(id: secondID, name: "owner", initials: "collide", order: 1, createdAt: createdAt),
        ]
        let pageOnlyBefore = snapshot(
            documents: documents,
            pageTitle: "Before",
            pageContent: "First body"
        )
        let pageOnlyAfter = snapshot(
            documents: documents,
            pageTitle: "After",
            pageContent: "Edited body"
        )
        let reordered = snapshot(
            documents: [
                document(
                    id: firstID,
                    name: "Owner",
                    initials: "COLLIDE",
                    order: 1,
                    createdAt: createdAt
                ),
                document(
                    id: secondID,
                    name: "owner",
                    initials: "collide",
                    order: 0,
                    createdAt: createdAt
                ),
            ],
            pageTitle: "After",
            pageContent: "Edited body"
        )
        let beforeRegistration = MyDocumentRegistrationPublication.capture(from: pageOnlyBefore)
        let pageEditRegistration = MyDocumentRegistrationPublication.capture(from: pageOnlyAfter)
        let reorderedRegistration = MyDocumentRegistrationPublication.capture(from: reordered)
        let notificationCount = RegistrationNotificationCounter()
        let token = NotificationCenter.default.addObserver(
            forName: SwordModuleStore.modulesDidChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            notificationCount.increment()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        MyDocumentRegistrationPublication.notifyIfChanged(
            from: beforeRegistration,
            to: pageEditRegistration
        )
        XCTAssertEqual(notificationCount.value, 0)

        MyDocumentRegistrationPublication.notifyIfChanged(
            from: pageEditRegistration,
            to: reorderedRegistration
        )
        XCTAssertEqual(notificationCount.value, 1)
    }

    /** Duplicate persisted UUIDs remain comparable without creating a notification crash boundary. */
    func testDuplicateDocumentIdentifiersRemainRepresentable() {
        let duplicateID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let firstOwner = document(
            id: duplicateID,
            name: "First owner",
            initials: "DUPLICATE",
            order: 0,
            createdAt: createdAt
        )
        let secondOwner = document(
            id: duplicateID,
            name: "Second owner",
            initials: "DUPLICATE-2",
            order: 1,
            createdAt: createdAt
        )

        let duplicateRegistration = MyDocumentRegistrationPublication.capture(
            from: snapshot(
                documents: [firstOwner, secondOwner],
                pageTitle: "Page",
                pageContent: "Body"
            )
        )
        let singleRegistration = MyDocumentRegistrationPublication.capture(
            from: snapshot(
                documents: [firstOwner],
                pageTitle: "Page",
                pageContent: "Body"
            )
        )

        XCTAssertNotEqual(duplicateRegistration, singleRegistration)
    }

    private func document(
        id: UUID,
        name: String,
        initials: String,
        order: Int,
        createdAt: Date
    ) -> RemoteSyncAndroidMyDocument {
        RemoteSyncAndroidMyDocument(
            id: id,
            name: name,
            documentDescription: nil,
            initials: initials,
            orderNumber: order,
            createdAt: createdAt,
            updatedAt: createdAt,
            sourcePromptId: nil
        )
    }

    private func snapshot(
        documents: [RemoteSyncAndroidMyDocument],
        pageTitle: String,
        pageContent: String
    ) -> RemoteSyncAndroidMyDocumentSnapshot {
        let pageID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let documentID = documents[0].id
        return RemoteSyncAndroidMyDocumentSnapshot(
            documents: documents,
            pages: [
                RemoteSyncAndroidMyDocumentPage(
                    id: pageID,
                    documentId: documentID,
                    title: pageTitle,
                    pageKey: "1",
                    contentType: .markdown,
                    orderNumber: 0,
                    createdAt: documents[0].createdAt,
                    updatedAt: documents[0].updatedAt,
                    sourcePromptId: nil,
                    languageCode: "en"
                )
            ],
            pageContents: [
                RemoteSyncAndroidMyDocumentPageContent(pageId: pageID, content: pageContent)
            ],
            aiPageCacheEntries: []
        )
    }
}

/** Thread-safe counter accepted by Foundation's sendable notification callback. */
private final class RegistrationNotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}
