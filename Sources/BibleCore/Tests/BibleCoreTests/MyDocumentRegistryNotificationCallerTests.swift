import Foundation
import SwiftData
import XCTest
@testable import BibleCore
import SwordKit

/** Caller-level payload-free registry notification coverage for My Documents management. */
@MainActor
final class MyDocumentRegistryNotificationCallerTests: XCTestCase {
    /** A registration rename wakes once after Save, while a later page-only Save remains silent. */
    func testManagementSavePublishesRegistrationRenameAndKeepsPageEditSilent() throws {
        let container = try makeContainer()
        let store = MyDocumentLibraryStore(modelContext: ModelContext(container))
        var session = try store.loadSession()
        let firstID = try session.createDocument(name: "First", initials: "FirstDoc")
        let pageID = try session.createPage(
            documentID: firstID,
            title: "Page",
            contentType: .markdown
        )
        try save(&session, through: store)

        let notificationCount = MyDocumentRegistryNotificationCounter()
        let token = NotificationCenter.default.addObserver(
            forName: SwordModuleStore.modulesDidChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            notificationCount.increment()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        try session.renameDocument(id: firstID, name: "Renamed")
        try save(&session, through: store)
        XCTAssertEqual(notificationCount.value, 1)

        try session.updatePage(
            documentID: firstID,
            pageID: pageID,
            title: "Page",
            contentType: .markdown,
            content: "Edited page body"
        )
        try save(&session, through: store)
        XCTAssertEqual(notificationCount.value, 1)
    }

    /** The shared draft projection retains fields normalized away from public session mutations. */
    func testDraftProjectionTracksOrderCreatedAtAndRawSortName() {
        let id = UUID(uuidString: "ce100000-0000-0000-0000-000000000001")!
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let baseline = MyDocumentDraft(
            id: id,
            name: "Owner",
            initials: "OWNER",
            orderNumber: 0,
            createdAt: createdAt,
            updatedAt: createdAt
        )
        let baselineProjection = MyDocumentRegistrationPublication.capture(from: [baseline])
        let reordered = MyDocumentDraft(
            id: id,
            name: baseline.name,
            initials: baseline.initials,
            orderNumber: 7,
            createdAt: createdAt,
            updatedAt: createdAt
        )
        let recreated = MyDocumentDraft(
            id: id,
            name: baseline.name,
            initials: baseline.initials,
            orderNumber: baseline.orderNumber,
            createdAt: createdAt.addingTimeInterval(1),
            updatedAt: createdAt
        )
        let rawNameChanged = MyDocumentDraft(
            id: id,
            name: " Owner ",
            initials: baseline.initials,
            orderNumber: baseline.orderNumber,
            createdAt: createdAt,
            updatedAt: createdAt
        )

        XCTAssertNotEqual(
            baselineProjection,
            MyDocumentRegistrationPublication.capture(from: [reordered])
        )
        XCTAssertNotEqual(
            baselineProjection,
            MyDocumentRegistrationPublication.capture(from: [recreated])
        )
        XCTAssertNotEqual(
            baselineProjection,
            MyDocumentRegistrationPublication.capture(from: [rawNameChanged])
        )
    }

    /** Saves one test session through the production registry admission and transaction path. */
    private func save(
        _ session: inout MyDocumentManagementSession,
        through store: MyDocumentLibraryStore
    ) throws {
        try store.save(&session, checkingInitialsWith: { _ in false })
    }

    /** Creates the isolated graph schema required by My Documents management Save. */
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            MyDocument.self,
            MyDocumentPage.self,
            MyDocumentPageContent.self,
            AiPageCacheEntry.self,
            Setting.self,
        ])
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
    }
}

/** Thread-safe counter accepted by Foundation's sendable notification callback. */
private final class MyDocumentRegistryNotificationCounter: @unchecked Sendable {
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
