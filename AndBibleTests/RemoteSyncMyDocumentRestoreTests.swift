// RemoteSyncMyDocumentRestoreTests.swift -- Android My Documents initial-backup restore tests

import CLibSword
import XCTest
import SQLite3
import SwiftData
@testable import BibleCore

private let myDocumentRestoreSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class RemoteSyncMyDocumentRestoreTests: XCTestCase {
    /**
     Verifies local My Documents insertion keeps Android bridge initials unique after
     removing SwiftData's CloudKit-incompatible unique constraint.

     The bridge resolves documents by initials, so allowing two local documents with the same
     initials would make reader actions nondeterministic and later Android-compatible exports
     fail against their unique initials index. The store should reject the duplicate before it
     reaches SwiftData persistence.
     */
    func testMyDocumentStoreRejectsDuplicateInitials() throws {
        let container = try makeModelContainer()
        let modelContext = ModelContext(container)
        let store = MyDocumentStore(modelContext: modelContext)

        XCTAssertTrue(store.insert(MyDocument(name: "First", initials: "MYDOC")))
        XCTAssertFalse(store.insert(MyDocument(name: "Duplicate", initials: "MYDOC")))

        let documents = try modelContext.fetch(FetchDescriptor<MyDocument>())
        XCTAssertEqual(documents.map(\.name), ["First"])
        XCTAssertEqual(store.document(initials: "MYDOC")?.name, "First")
    }

    func testRemoteSyncMyDocumentRestoreReplacesLocalGraphAndPreservesAIContext() throws {
        let container = try makeModelContainer()
        let modelContext = ModelContext(container)
        let store = MyDocumentStore(modelContext: modelContext)
        modelContext.insert(MyDocument(name: "Legacy", initials: "LEGACY"))
        try modelContext.save()

        let documentID = UUID(uuidString: "a1000000-0000-0000-0000-000000000001")!
        let pageID = UUID(uuidString: "a1000000-0000-0000-0000-000000000011")!
        let promptID = UUID(uuidString: "a1000000-0000-0000-0000-000000000021")!
        let createdAt = Date(timeIntervalSince1970: 1_735_689_600)
        let updatedAt = Date(timeIntervalSince1970: 1_735_689_660)
        let databaseURL = try makeAndroidMyDocumentsDatabase(
            documents: [
                .init(
                    id: documentID,
                    name: "Android Document",
                    documentDescription: "Imported",
                    initials: "MYDOC",
                    orderNumber: 2,
                    createdAt: createdAt,
                    updatedAt: updatedAt,
                    sourcePromptId: nil
                )
            ],
            pages: [
                .init(
                    id: pageID,
                    documentId: documentID,
                    title: "Intro",
                    pageKey: "intro",
                    contentType: .markdown,
                    orderNumber: 1,
                    createdAt: createdAt,
                    updatedAt: updatedAt,
                    sourcePromptId: promptID,
                    languageCode: "en"
                )
            ],
            pageContents: [
                .init(pageId: pageID, content: "Restored **markdown**")
            ],
            aiPageCacheEntries: [
                .init(
                    pageId: pageID,
                    sourcePromptId: promptID,
                    sourceContext: #"{"osisRef":"Gen.1"}"#,
                    kjvOrdinalStart: 1,
                    kjvOrdinalEnd: 31,
                    contextHash: "ctx-hash",
                    usedWriteTools: true,
                    sourceModelName: "gpt-test",
                    sourceBookInitials: "KJV",
                    sourceBookKey: "Gen.1"
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let service = RemoteSyncMyDocumentRestoreService()
        let snapshot = try service.readSnapshot(from: databaseURL)
        let report = try service.replaceLocalMyDocuments(from: snapshot, modelContext: modelContext)

        XCTAssertEqual(
            report,
            .init(
                restoredDocumentCount: 1,
                restoredPageCount: 1,
                restoredContentCount: 1,
                restoredAIPageCacheEntryCount: 1
            )
        )
        XCTAssertNil(store.document(initials: "LEGACY"))

        let payload = try XCTUnwrap(store.rawContentPayload(bookInitials: "MYDOC", pageKey: "intro"))
        XCTAssertEqual(payload.pageId, pageID.uuidString)
        XCTAssertEqual(payload.contentType, "MARKDOWN")
        XCTAssertEqual(payload.content, "Restored **markdown**")
        XCTAssertEqual(payload.title, "Intro")
        XCTAssertEqual(payload.sourcePromptId, promptID.uuidString)

        let actionContext = try XCTUnwrap(store.aiPageActionContext(pageId: pageID))
        XCTAssertEqual(actionContext.documentId, documentID)
        XCTAssertEqual(actionContext.sourcePromptId, promptID)
        XCTAssertEqual(actionContext.sourceContext, #"{"osisRef":"Gen.1"}"#)
        XCTAssertEqual(actionContext.kjvOrdinalStart, 1)
        XCTAssertEqual(actionContext.kjvOrdinalEnd, 31)
        XCTAssertEqual(actionContext.contextHash, "ctx-hash")
        XCTAssertTrue(actionContext.usedWriteTools)
        XCTAssertEqual(actionContext.sourceModelName, "gpt-test")
        XCTAssertEqual(actionContext.sourceBookInitials, "KJV")
        XCTAssertEqual(actionContext.sourceBookKey, "Gen.1")

        let documents = try modelContext.fetch(FetchDescriptor<MyDocument>())
        XCTAssertEqual(documents.map(\.id), [documentID])
        XCTAssertEqual(documents[0].createdAt, createdAt)
        XCTAssertEqual(documents[0].updatedAt, updatedAt)
    }

    func testRemoteSyncMyDocumentRestoreRejectsOrphansWithoutMutation() throws {
        let container = try makeModelContainer()
        let modelContext = ModelContext(container)
        let existingDocument = MyDocument(name: "Existing", initials: "EXISTING")
        modelContext.insert(existingDocument)
        try modelContext.save()

        let orphanPageID = UUID(uuidString: "b1000000-0000-0000-0000-000000000011")!
        let missingDocumentID = UUID(uuidString: "b1000000-0000-0000-0000-000000000099")!
        let databaseURL = try makeAndroidMyDocumentsDatabase(
            documents: [],
            pages: [
                .init(
                    id: orphanPageID,
                    documentId: missingDocumentID,
                    title: "Orphan",
                    pageKey: "orphan",
                    contentType: .markdown
                )
            ],
            pageContents: [],
            aiPageCacheEntries: []
        )
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let service = RemoteSyncMyDocumentRestoreService()
        let snapshot = try service.readSnapshot(from: databaseURL)
        XCTAssertThrowsError(
            try service.replaceLocalMyDocuments(from: snapshot, modelContext: modelContext)
        ) { error in
            XCTAssertEqual(
                error as? RemoteSyncMyDocumentRestoreError,
                .orphanReferences([
                    "MyDocumentPage.id=\(orphanPageID.uuidString) missing MyDocument"
                ])
            )
        }

        let documents = try modelContext.fetch(FetchDescriptor<MyDocument>())
        XCTAssertEqual(documents.map(\.initials), ["EXISTING"])
    }

    /**
     Verifies staged Android My Documents rows cannot introduce duplicate bridge initials.

     CloudKit does not allow SwiftData to keep `MyDocument.initials` as a store-level unique
     constraint, but Android bridge lookup and remote backup uploads still require one document
     per initials value. Invalid remote data must be rejected before the restore deletes current
     local rows so the app remains on a deterministic, exportable graph.
     */
    func testRemoteSyncMyDocumentRestoreRejectsDuplicateInitialsWithoutMutation() throws {
        let container = try makeModelContainer()
        let modelContext = ModelContext(container)
        let existingDocument = MyDocument(name: "Existing", initials: "EXISTING")
        modelContext.insert(existingDocument)
        try modelContext.save()

        let firstDocumentID = UUID(uuidString: "e1000000-0000-0000-0000-000000000001")!
        let secondDocumentID = UUID(uuidString: "e1000000-0000-0000-0000-000000000002")!
        let databaseURL = try makeAndroidMyDocumentsDatabase(
            documents: [
                .init(id: firstDocumentID, name: "First", initials: "DUP"),
                .init(id: secondDocumentID, name: "Second", initials: "DUP"),
            ],
            pages: [],
            pageContents: [],
            aiPageCacheEntries: []
        )
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let service = RemoteSyncMyDocumentRestoreService()
        let snapshot = try service.readSnapshot(from: databaseURL)
        XCTAssertThrowsError(
            try service.replaceLocalMyDocuments(from: snapshot, modelContext: modelContext)
        ) { error in
            XCTAssertEqual(error as? RemoteSyncMyDocumentRestoreError, .duplicateInitials(["DUP"]))
        }

        let documents = try modelContext.fetch(FetchDescriptor<MyDocument>())
        XCTAssertEqual(documents.map(\.initials), ["EXISTING"])
    }

    func testRemoteSyncMyDocumentRestoreRejectsMalformedContentType() throws {
        let documentID = UUID(uuidString: "d1000000-0000-0000-0000-000000000001")!
        let pageID = UUID(uuidString: "d1000000-0000-0000-0000-000000000011")!
        let databaseURL = try makeAndroidMyDocumentsDatabase(
            documents: [
                .init(id: documentID, name: "Malformed", initials: "BAD")
            ],
            pages: [
                .init(
                    id: pageID,
                    documentId: documentID,
                    title: "Malformed Page",
                    pageKey: "bad",
                    contentTypeRawValue: "PDF"
                )
            ],
            pageContents: [],
            aiPageCacheEntries: []
        )
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let service = RemoteSyncMyDocumentRestoreService()
        XCTAssertThrowsError(try service.readSnapshot(from: databaseURL)) { error in
            XCTAssertEqual(
                error as? RemoteSyncMyDocumentRestoreError,
                .invalidColumnValue(table: "MyDocumentPage", column: "contentType")
            )
        }
    }

    func testRemoteSyncInitialBackupRestoreDispatchesMyDocumentBackups() throws {
        let container = try makeModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let dispatcher = RemoteSyncInitialBackupRestoreService()
        let documentID = UUID(uuidString: "c1000000-0000-0000-0000-000000000001")!
        let pageID = UUID(uuidString: "c1000000-0000-0000-0000-000000000011")!
        let promptID = UUID(uuidString: "c1000000-0000-0000-0000-000000000021")!
        let logEntry = RemoteSyncLogEntry(
            tableName: "MyDocument",
            entityID1: .blob(uuidBlob(documentID)),
            entityID2: .text(""),
            type: .upsert,
            lastUpdated: 1_735_689_600_000,
            sourceDevice: "pixel"
        )
        let patchStatus = RemoteSyncPatchStatus(
            sourceDevice: "pixel",
            patchNumber: 3,
            sizeBytes: 2_048,
            appliedDate: 1_735_689_650_000
        )
        let databaseURL = try makeAndroidMyDocumentsDatabase(
            documents: [
                .init(id: documentID, name: "Dispatch", initials: "DISP")
            ],
            pages: [
                .init(
                    id: pageID,
                    documentId: documentID,
                    title: "Dispatch Page",
                    pageKey: "dispatch",
                    contentType: .html,
                    sourcePromptId: promptID
                )
            ],
            pageContents: [
                .init(pageId: pageID, content: "<p>Dispatch</p>")
            ],
            aiPageCacheEntries: [
                .init(pageId: pageID, sourcePromptId: promptID)
            ],
            logEntries: [logEntry],
            syncStatuses: [patchStatus]
        )
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let report = try dispatcher.restoreInitialBackup(
            RemoteSyncStagedInitialBackup(
                remoteFile: RemoteSyncFile(
                    id: "/org.andbible.ios-sync-mydocuments/initial.sqlite3.gz",
                    name: "initial.sqlite3.gz",
                    size: 4_096,
                    timestamp: 1_735_689_600_000,
                    parentID: "/org.andbible.ios-sync-mydocuments",
                    mimeType: "application/gzip"
                ),
                databaseFileURL: databaseURL,
                schemaVersion: 4
            ),
            category: .myDocuments,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(
            report,
            .myDocuments(
                .init(
                    restoredDocumentCount: 1,
                    restoredPageCount: 1,
                    restoredContentCount: 1,
                    restoredAIPageCacheEntryCount: 1
                )
            )
        )

        let store = MyDocumentStore(modelContext: modelContext)
        XCTAssertEqual(
            store.rawContentPayload(bookInitials: "DISP", pageKey: "dispatch")?.content,
            "<p>Dispatch</p>"
        )
        XCTAssertEqual(
            RemoteSyncLogEntryStore(settingsStore: settingsStore).entries(for: .myDocuments),
            [logEntry]
        )
        XCTAssertEqual(
            RemoteSyncPatchStatusStore(settingsStore: settingsStore).statuses(for: .myDocuments),
            [patchStatus]
        )

        let fingerprintStore = RemoteSyncRowFingerprintStore(settingsStore: settingsStore)
        XCTAssertNotNil(
            fingerprintStore.fingerprint(
                for: .myDocuments,
                tableName: "MyDocument",
                entityID1: .blob(uuidBlob(documentID)),
                entityID2: .text("")
            )
        )
        XCTAssertNotNil(
            fingerprintStore.fingerprint(
                for: .myDocuments,
                tableName: "MyDocumentPage",
                entityID1: .blob(uuidBlob(pageID)),
                entityID2: .text("")
            )
        )
        XCTAssertNotNil(
            fingerprintStore.fingerprint(
                for: .myDocuments,
                tableName: "MyDocumentPageContent",
                entityID1: .blob(uuidBlob(pageID)),
                entityID2: .text("")
            )
        )
        XCTAssertNotNil(
            fingerprintStore.fingerprint(
                for: .myDocuments,
                tableName: "AiPageCacheEntry",
                entityID1: .blob(uuidBlob(pageID)),
                entityID2: .text("")
            )
        )
    }

    func testRemoteSyncMyDocumentSnapshotFiltersOrphansAndRefreshesBaseline() throws {
        let container = try makeModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let documentID = UUID(uuidString: "f1000000-0000-0000-0000-000000000001")!
        let validPageID = UUID(uuidString: "f1000000-0000-0000-0000-000000000011")!
        let orphanPageID = UUID(uuidString: "f1000000-0000-0000-0000-000000000012")!
        let missingPageID = UUID(uuidString: "f1000000-0000-0000-0000-000000000013")!
        let promptID = UUID(uuidString: "f1000000-0000-0000-0000-000000000021")!
        let duplicatePromptID = UUID(uuidString: "f1000000-0000-0000-0000-000000000022")!
        let selectedCacheEntryID = UUID(uuidString: "f1000000-0000-0000-0000-000000000031")!
        let duplicateCacheEntryID = UUID(uuidString: "f1000000-0000-0000-0000-000000000032")!
        let staleDocumentID = UUID(uuidString: "f1000000-0000-0000-0000-000000000099")!

        let document = MyDocument(
            id: documentID,
            name: "Snapshot",
            initials: "SNAP"
        )
        let validPage = MyDocumentPage(
            id: validPageID,
            title: "Valid",
            pageKey: "valid"
        )
        let validContent = MyDocumentPageContent(pageId: validPageID, content: "Valid content")
        let validCacheEntry = AiPageCacheEntry(
            id: selectedCacheEntryID,
            pageId: validPageID,
            sourcePromptId: promptID,
            contextHash: "valid"
        )
        let duplicateCacheEntry = AiPageCacheEntry(
            id: duplicateCacheEntryID,
            pageId: validPageID,
            sourcePromptId: duplicatePromptID,
            contextHash: "duplicate"
        )
        document.pages = [validPage]
        validPage.document = document
        validPage.pageContent = validContent
        validContent.page = validPage
        validPage.aiPageCacheEntries = [validCacheEntry, duplicateCacheEntry]
        validCacheEntry.page = validPage
        duplicateCacheEntry.page = validPage

        let orphanPage = MyDocumentPage(
            id: orphanPageID,
            title: "Orphan",
            pageKey: "orphan"
        )
        let orphanContent = MyDocumentPageContent(pageId: orphanPageID, content: "Orphan content")
        let orphanCacheEntry = AiPageCacheEntry(
            pageId: orphanPageID,
            sourcePromptId: promptID,
            contextHash: "orphan"
        )
        orphanPage.pageContent = orphanContent
        orphanContent.page = orphanPage
        orphanPage.aiPageCacheEntries = [orphanCacheEntry]
        orphanCacheEntry.page = orphanPage

        let missingPageContent = MyDocumentPageContent(pageId: missingPageID, content: "Missing content")
        let missingPageCacheEntry = AiPageCacheEntry(
            pageId: missingPageID,
            sourcePromptId: promptID,
            contextHash: "missing"
        )

        modelContext.insert(document)
        modelContext.insert(validPage)
        modelContext.insert(validContent)
        modelContext.insert(validCacheEntry)
        modelContext.insert(duplicateCacheEntry)
        modelContext.insert(orphanPage)
        modelContext.insert(orphanContent)
        modelContext.insert(orphanCacheEntry)
        modelContext.insert(missingPageContent)
        modelContext.insert(missingPageCacheEntry)
        try modelContext.save()

        let service = RemoteSyncMyDocumentSnapshotService()
        let snapshot = service.snapshotCurrentState(
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(Set(snapshot.documentRowsByKey.values.map(\.id)), [documentID])
        XCTAssertEqual(Set(snapshot.pageRowsByKey.values.map(\.id)), [validPageID])
        XCTAssertEqual(Set(snapshot.pageContentRowsByKey.values.map(\.pageId)), [validPageID])
        XCTAssertEqual(Set(snapshot.aiPageCacheEntryRowsByKey.values.map(\.pageId)), [validPageID])
        XCTAssertEqual(snapshot.aiPageCacheEntryRowsByKey.values.first?.contextHash, "valid")
        XCTAssertEqual(snapshot.fingerprintsByKey.count, 4)

        let fingerprintStore = RemoteSyncRowFingerprintStore(settingsStore: settingsStore)
        fingerprintStore.setFingerprint(
            "stale",
            for: .myDocuments,
            tableName: "MyDocument",
            entityID1: .blob(uuidBlob(staleDocumentID)),
            entityID2: .text("")
        )

        service.refreshBaselineFingerprints(
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertNil(
            fingerprintStore.fingerprint(
                for: .myDocuments,
                tableName: "MyDocument",
                entityID1: .blob(uuidBlob(staleDocumentID)),
                entityID2: .text("")
            )
        )
        XCTAssertNotNil(
            fingerprintStore.fingerprint(
                for: .myDocuments,
                tableName: "MyDocument",
                entityID1: .blob(uuidBlob(documentID)),
                entityID2: .text("")
            )
        )
        XCTAssertNotNil(
            fingerprintStore.fingerprint(
                for: .myDocuments,
                tableName: "MyDocumentPage",
                entityID1: .blob(uuidBlob(validPageID)),
                entityID2: .text("")
            )
        )
        XCTAssertNotNil(
            fingerprintStore.fingerprint(
                for: .myDocuments,
                tableName: "MyDocumentPageContent",
                entityID1: .blob(uuidBlob(validPageID)),
                entityID2: .text("")
            )
        )
        XCTAssertNotNil(
            fingerprintStore.fingerprint(
                for: .myDocuments,
                tableName: "AiPageCacheEntry",
                entityID1: .blob(uuidBlob(validPageID)),
                entityID2: .text("")
            )
        )
    }

    func testRemoteSyncInitialBackupUploadWritesMyDocumentDatabaseAndResetsBaseline() async throws {
        let container = try makeModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let documentID = UUID(uuidString: "e1000000-0000-0000-0000-000000000001")!
        let pageID = UUID(uuidString: "e1000000-0000-0000-0000-000000000011")!
        let documentPromptID = UUID(uuidString: "e1000000-0000-0000-0000-000000000021")!
        let pagePromptID = UUID(uuidString: "e1000000-0000-0000-0000-000000000022")!
        let createdAt = Date(timeIntervalSince1970: 1_735_689_600)
        let updatedAt = Date(timeIntervalSince1970: 1_735_689_660)
        let document = MyDocument(
            id: documentID,
            name: "iOS Document",
            documentDescription: "Exported from iOS",
            initials: "IOSDOC",
            orderNumber: 4,
            createdAt: createdAt,
            updatedAt: updatedAt,
            sourcePromptId: documentPromptID
        )
        let page = MyDocumentPage(
            id: pageID,
            title: "Intro",
            pageKey: "intro",
            contentType: .html,
            orderNumber: 2,
            createdAt: createdAt,
            updatedAt: updatedAt,
            sourcePromptId: pagePromptID,
            languageCode: "en"
        )
        let content = MyDocumentPageContent(pageId: pageID, content: "<p>Exported</p>")
        let cacheEntry = AiPageCacheEntry(
            pageId: pageID,
            sourcePromptId: pagePromptID,
            sourceContext: #"{"osisRef":"John.3.16"}"#,
            kjvOrdinalStart: 26_136,
            kjvOrdinalEnd: 26_136,
            contextHash: "ios-context",
            usedWriteTools: true,
            sourceModelName: "gpt-test",
            sourceBookInitials: "KJV",
            sourceBookKey: "John.3.16"
        )
        document.pages = [page]
        page.document = document
        page.pageContent = content
        content.page = page
        page.aiPageCacheEntries = [cacheEntry]
        cacheEntry.page = page
        modelContext.insert(document)
        modelContext.insert(page)
        modelContext.insert(content)
        modelContext.insert(cacheEntry)
        try modelContext.save()

        RemoteSyncLogEntryStore(settingsStore: settingsStore).addEntry(
            RemoteSyncLogEntry(
                tableName: "MyDocument",
                entityID1: .blob(uuidBlob(documentID)),
                entityID2: .text(""),
                type: .upsert,
                lastUpdated: 1_735_689_600_000,
                sourceDevice: "android"
            ),
            for: .myDocuments
        )

        let syncFolderID = "/org.andbible.ios-sync-mydocuments"
        let adapter = MyDocumentMockRemoteSyncAdapter()
        await adapter.enqueueUploadResult(
            RemoteSyncFile(
                id: "\(syncFolderID)/initial.sqlite3.gz",
                name: "initial.sqlite3.gz",
                size: 0,
                timestamp: 2_000,
                parentID: syncFolderID,
                mimeType: NextCloudSyncAdapter.gzipMimeType
            )
        )
        let service = RemoteSyncInitialBackupUploadService(
            adapter: adapter,
            deviceIdentifier: "ios-device",
            nowProvider: { 1_900 }
        )

        let report = try await service.uploadInitialBackup(
            for: .myDocuments,
            bootstrapState: RemoteSyncBootstrapState(syncFolderID: syncFolderID),
            modelContext: modelContext,
            settingsStore: settingsStore,
            schemaVersion: RemoteSyncMyDocumentRestoreService.supportedAndroidSchemaVersion
        )

        XCTAssertEqual(report.category, .myDocuments)
        XCTAssertTrue(RemoteSyncLogEntryStore(settingsStore: settingsStore).entries(for: .myDocuments).isEmpty)
        XCTAssertEqual(
            RemoteSyncPatchStatusStore(settingsStore: settingsStore).statuses(for: .myDocuments),
            [
                RemoteSyncPatchStatus(
                    sourceDevice: "ios-device",
                    patchNumber: 0,
                    sizeBytes: report.uploadedFile.size,
                    appliedDate: 2_000
                )
            ]
        )
        XCTAssertEqual(RemoteSyncStateStore(settingsStore: settingsStore).progressState(for: .myDocuments).lastPatchWritten, 1_900)
        let fingerprintStore = RemoteSyncRowFingerprintStore(settingsStore: settingsStore)
        XCTAssertNotNil(
            fingerprintStore.fingerprint(
                for: .myDocuments,
                tableName: "MyDocument",
                entityID1: .blob(uuidBlob(documentID)),
                entityID2: .text("")
            )
        )
        XCTAssertNotNil(
            fingerprintStore.fingerprint(
                for: .myDocuments,
                tableName: "MyDocumentPage",
                entityID1: .blob(uuidBlob(pageID)),
                entityID2: .text("")
            )
        )
        XCTAssertNotNil(
            fingerprintStore.fingerprint(
                for: .myDocuments,
                tableName: "MyDocumentPageContent",
                entityID1: .blob(uuidBlob(pageID)),
                entityID2: .text("")
            )
        )
        XCTAssertNotNil(
            fingerprintStore.fingerprint(
                for: .myDocuments,
                tableName: "AiPageCacheEntry",
                entityID1: .blob(uuidBlob(pageID)),
                entityID2: .text("")
            )
        )

        let uploadedFiles = await adapter.uploadedFilesSnapshot()
        let uploadedFile = try XCTUnwrap(uploadedFiles.first)
        XCTAssertEqual(uploadedFile.name, "initial.sqlite3.gz")
        XCTAssertEqual(uploadedFile.parentID, syncFolderID)
        XCTAssertEqual(uploadedFile.contentType, NextCloudSyncAdapter.gzipMimeType)
        let databaseURL = try writeUploadedMyDocumentDatabase(uploadedFile.data)
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        XCTAssertEqual(try sqliteUserVersion(at: databaseURL), RemoteSyncMyDocumentRestoreService.supportedAndroidSchemaVersion)
        XCTAssertEqual(try sqliteRoomIdentityHash(at: databaseURL), "3f0946602099d896c8d47129233c1794")
        XCTAssertNil(try sqliteColumnDefault(tableName: "LogEntry", columnName: "entityId2", databaseURL: databaseURL))
        let snapshot = try RemoteSyncMyDocumentRestoreService().readSnapshot(from: databaseURL)
        XCTAssertEqual(snapshot.documents.count, 1)
        XCTAssertEqual(snapshot.documents[0].id, documentID)
        XCTAssertEqual(snapshot.documents[0].documentDescription, "Exported from iOS")
        XCTAssertEqual(snapshot.pages.count, 1)
        XCTAssertEqual(snapshot.pages[0].contentType, .html)
        XCTAssertEqual(snapshot.pageContents, [.init(pageId: pageID, content: "<p>Exported</p>")])
        XCTAssertEqual(snapshot.aiPageCacheEntries.count, 1)
        XCTAssertEqual(snapshot.aiPageCacheEntries[0].sourceBookKey, "John.3.16")

        let secondContainer = try makeModelContainer()
        let secondModelContext = ModelContext(secondContainer)
        let restoreReport = try RemoteSyncMyDocumentRestoreService().replaceLocalMyDocuments(
            from: snapshot,
            modelContext: secondModelContext
        )
        XCTAssertEqual(restoreReport.restoredDocumentCount, 1)
        XCTAssertEqual(
            MyDocumentStore(modelContext: secondModelContext).rawContentPayload(bookInitials: "IOSDOC", pageKey: "intro")?.content,
            "<p>Exported</p>"
        )
    }

    func testRemoteSyncInitialBackupUploadWritesDeterministicEmptyMyDocumentDatabase() async throws {
        let container = try makeModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let syncFolderID = "/org.andbible.ios-sync-mydocuments-empty"
        let adapter = MyDocumentMockRemoteSyncAdapter()
        await adapter.enqueueUploadResult(
            RemoteSyncFile(
                id: "\(syncFolderID)/initial.sqlite3.gz",
                name: "initial.sqlite3.gz",
                size: 0,
                timestamp: 2_500,
                parentID: syncFolderID,
                mimeType: NextCloudSyncAdapter.gzipMimeType
            )
        )
        let service = RemoteSyncInitialBackupUploadService(
            adapter: adapter,
            deviceIdentifier: "ios-device",
            nowProvider: { 2_400 }
        )

        _ = try await service.uploadInitialBackup(
            for: .myDocuments,
            bootstrapState: RemoteSyncBootstrapState(syncFolderID: syncFolderID),
            modelContext: modelContext,
            settingsStore: settingsStore,
            schemaVersion: RemoteSyncMyDocumentRestoreService.supportedAndroidSchemaVersion
        )

        let uploadedFiles = await adapter.uploadedFilesSnapshot()
        let uploadedFile = try XCTUnwrap(uploadedFiles.first)
        let databaseURL = try writeUploadedMyDocumentDatabase(uploadedFile.data)
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let snapshot = try RemoteSyncMyDocumentRestoreService().readSnapshot(from: databaseURL)

        XCTAssertTrue(snapshot.documents.isEmpty)
        XCTAssertTrue(snapshot.pages.isEmpty)
        XCTAssertTrue(snapshot.pageContents.isEmpty)
        XCTAssertTrue(snapshot.aiPageCacheEntries.isEmpty)
        XCTAssertEqual(try sqliteCount(tableName: "MyDocument", databaseURL: databaseURL), 0)
        XCTAssertEqual(try sqliteCount(tableName: "AiPageCacheEntry", databaseURL: databaseURL), 0)
        XCTAssertTrue(
            settingsStore.entries(
                withPrefix: RemoteSyncRowFingerprintStore(settingsStore: settingsStore).prefix(for: .myDocuments)
            ).isEmpty
        )
        XCTAssertEqual(RemoteSyncStateStore(settingsStore: settingsStore).progressState(for: .myDocuments).lastPatchWritten, 2_400)
    }

    func testRemoteSyncMyDocumentPatchReplayAppliesUpdatesDeletesAndSparseRows() throws {
        let container = try makeModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)

        let documentID = UUID(uuidString: "a8100000-0000-0000-0000-000000000001")!
        let existingPageID = UUID(uuidString: "a8100000-0000-0000-0000-000000000011")!
        let existingPromptID = UUID(uuidString: "a8100000-0000-0000-0000-000000000021")!
        let remotePromptID = UUID(uuidString: "a8100000-0000-0000-0000-000000000022")!
        let newDocumentID = UUID(uuidString: "a8100000-0000-0000-0000-000000000002")!
        let newPageID = UUID(uuidString: "a8100000-0000-0000-0000-000000000012")!
        let deletedDocumentID = UUID(uuidString: "a8100000-0000-0000-0000-000000000003")!
        let deletedPageID = UUID(uuidString: "a8100000-0000-0000-0000-000000000013")!
        let orphanPageID = UUID(uuidString: "a8100000-0000-0000-0000-000000000014")!
        let missingDocumentID = UUID(uuidString: "a8100000-0000-0000-0000-000000000099")!
        let createdAt = Date(timeIntervalSince1970: 1_735_689_600)
        let remoteUpdatedAt = Date(timeIntervalSince1970: 1_735_689_900)

        let existingDocument = MyDocument(
            id: documentID,
            name: "Local",
            initials: "LOC",
            createdAt: createdAt,
            updatedAt: createdAt
        )
        let existingPage = MyDocumentPage(
            id: existingPageID,
            title: "Local Page",
            pageKey: "local",
            sourcePromptId: existingPromptID
        )
        let existingContent = MyDocumentPageContent(pageId: existingPageID, content: "Local content")
        let existingCacheEntry = AiPageCacheEntry(
            pageId: existingPageID,
            sourcePromptId: existingPromptID,
            contextHash: "local-cache"
        )
        existingDocument.pages = [existingPage]
        existingPage.document = existingDocument
        existingPage.pageContent = existingContent
        existingContent.page = existingPage
        existingPage.aiPageCacheEntries = [existingCacheEntry]
        existingCacheEntry.page = existingPage

        let deletedDocument = MyDocument(id: deletedDocumentID, name: "Deleted", initials: "DEL")
        let deletedPage = MyDocumentPage(id: deletedPageID, title: "Deleted Page", pageKey: "deleted")
        let deletedContent = MyDocumentPageContent(pageId: deletedPageID, content: "Delete me")
        deletedDocument.pages = [deletedPage]
        deletedPage.document = deletedDocument
        deletedPage.pageContent = deletedContent
        deletedContent.page = deletedPage

        modelContext.insert(existingDocument)
        modelContext.insert(existingPage)
        modelContext.insert(existingContent)
        modelContext.insert(existingCacheEntry)
        modelContext.insert(deletedDocument)
        modelContext.insert(deletedPage)
        modelContext.insert(deletedContent)
        try modelContext.save()

        logEntryStore.replaceEntries(
            myDocumentLogEntries(
                documentIDs: [documentID, deletedDocumentID],
                pageIDs: [existingPageID, deletedPageID],
                timestamp: 1_000,
                sourceDevice: "iphone"
            ),
            for: .myDocuments
        )

        let patchLogEntries: [RemoteSyncLogEntry] = [
            myDocumentLogEntry(tableName: "MyDocument", rowID: documentID, type: .upsert),
            myDocumentLogEntry(tableName: "MyDocument", rowID: newDocumentID, type: .upsert),
            myDocumentLogEntry(tableName: "MyDocumentPage", rowID: newPageID, type: .upsert),
            myDocumentLogEntry(tableName: "MyDocumentPage", rowID: orphanPageID, type: .upsert),
            myDocumentLogEntry(tableName: "MyDocumentPageContent", rowID: existingPageID, type: .upsert),
            myDocumentLogEntry(tableName: "MyDocumentPageContent", rowID: newPageID, type: .upsert),
            myDocumentLogEntry(tableName: "MyDocumentPageContent", rowID: orphanPageID, type: .upsert),
            myDocumentLogEntry(tableName: "AiPageCacheEntry", rowID: existingPageID, type: .upsert),
            myDocumentLogEntry(tableName: "MyDocument", rowID: deletedDocumentID, type: .delete),
        ]
        let stagedArchive = try makeStagedMyDocumentPatchArchive(
            sourceDevice: "pixel",
            patchNumber: 1,
            timestamp: 7_000,
            documents: [
                .init(
                    id: documentID,
                    name: "Remote Updated",
                    documentDescription: "Remote metadata",
                    initials: "LOC",
                    orderNumber: 4,
                    createdAt: createdAt,
                    updatedAt: remoteUpdatedAt
                ),
                .init(
                    id: newDocumentID,
                    name: "Remote New",
                    initials: "NEW",
                    orderNumber: 5,
                    createdAt: createdAt,
                    updatedAt: remoteUpdatedAt
                ),
            ],
            pages: [
                .init(
                    id: newPageID,
                    documentId: newDocumentID,
                    title: "New Page",
                    pageKey: "new",
                    contentType: .html,
                    orderNumber: 1,
                    createdAt: createdAt,
                    updatedAt: remoteUpdatedAt
                ),
                .init(
                    id: orphanPageID,
                    documentId: missingDocumentID,
                    title: "Orphan Page",
                    pageKey: "orphan",
                    contentType: .markdown,
                    orderNumber: 2,
                    createdAt: createdAt,
                    updatedAt: remoteUpdatedAt
                )
            ],
            pageContents: [
                .init(pageId: existingPageID, content: "Remote content only"),
                .init(pageId: newPageID, content: "<p>Remote new</p>"),
                .init(pageId: orphanPageID, content: "Orphan content"),
            ],
            aiPageCacheEntries: [
                .init(
                    pageId: existingPageID,
                    sourcePromptId: remotePromptID,
                    contextHash: "remote-cache",
                    sourceBookKey: "Gen.1"
                )
            ],
            logEntries: patchLogEntries
        )
        defer { try? FileManager.default.removeItem(at: stagedArchive.archiveFileURL) }

        let report = try RemoteSyncMyDocumentPatchApplyService().applyPatchArchives(
            [stagedArchive],
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(report.appliedPatchCount, 1)
        XCTAssertEqual(report.appliedLogEntryCount, 9)
        XCTAssertEqual(report.skippedLogEntryCount, 0)
        XCTAssertEqual(
            report.restoreReport,
            .init(
                restoredDocumentCount: 2,
                restoredPageCount: 2,
                restoredContentCount: 2,
                restoredAIPageCacheEntryCount: 1
            )
        )

        let store = MyDocumentStore(modelContext: modelContext)
        XCTAssertEqual(store.document(initials: "LOC")?.name, "Remote Updated")
        XCTAssertEqual(
            store.rawContentPayload(bookInitials: "LOC", pageKey: "local")?.content,
            "Remote content only"
        )
        XCTAssertEqual(
            store.rawContentPayload(bookInitials: "NEW", pageKey: "new")?.content,
            "<p>Remote new</p>"
        )
        XCTAssertNil(store.document(initials: "DEL"))
        XCTAssertNil(store.page(pageId: deletedPageID))
        XCTAssertNil(store.page(pageId: orphanPageID))
        XCTAssertEqual(
            store.aiPageActionContext(pageId: existingPageID)?.contextHash,
            "remote-cache"
        )

        XCTAssertEqual(
            RemoteSyncPatchStatusStore(settingsStore: settingsStore).statuses(for: .myDocuments),
            [
                RemoteSyncPatchStatus(
                    sourceDevice: "pixel",
                    patchNumber: 1,
                    sizeBytes: stagedArchive.patch.file.size,
                    appliedDate: 7_000
                )
            ]
        )
        XCTAssertTrue(
            logEntryStore.entries(for: .myDocuments).contains(
                myDocumentLogEntry(
                    tableName: "MyDocument",
                    rowID: deletedDocumentID,
                    type: .delete
                )
            )
        )
    }

    func testRemoteSyncMyDocumentPatchReplaySkipsOlderRowsAndRecordsPatchStatus() throws {
        let container = try makeModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let documentID = UUID(uuidString: "a8200000-0000-0000-0000-000000000001")!

        modelContext.insert(MyDocument(id: documentID, name: "Local Newer", initials: "SKIP"))
        try modelContext.save()

        let localLogEntry = myDocumentLogEntry(
            tableName: "MyDocument",
            rowID: documentID,
            type: .upsert,
            timestamp: 5_000,
            sourceDevice: "iphone"
        )
        logEntryStore.replaceEntries([localLogEntry], for: .myDocuments)
        let stagedArchive = try makeStagedMyDocumentPatchArchive(
            sourceDevice: "pixel",
            patchNumber: 2,
            timestamp: 8_000,
            documents: [
                .init(id: documentID, name: "Remote Older", initials: "SKIP")
            ],
            pages: [],
            pageContents: [],
            aiPageCacheEntries: [],
            logEntries: [
                myDocumentLogEntry(
                    tableName: "MyDocument",
                    rowID: documentID,
                    type: .upsert,
                    timestamp: 1_000,
                    sourceDevice: "pixel"
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: stagedArchive.archiveFileURL) }

        let report = try RemoteSyncMyDocumentPatchApplyService().applyPatchArchives(
            [stagedArchive],
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(report.appliedPatchCount, 1)
        XCTAssertEqual(report.appliedLogEntryCount, 0)
        XCTAssertEqual(report.skippedLogEntryCount, 1)
        XCTAssertEqual(report.restoreReport.restoredDocumentCount, 1)
        XCTAssertEqual(MyDocumentStore(modelContext: modelContext).document(initials: "SKIP")?.name, "Local Newer")
        XCTAssertEqual(logEntryStore.entries(for: .myDocuments), [localLogEntry])
        XCTAssertEqual(
            RemoteSyncPatchStatusStore(settingsStore: settingsStore).status(
                for: .myDocuments,
                sourceDevice: "pixel",
                patchNumber: 2
            ),
            RemoteSyncPatchStatus(
                sourceDevice: "pixel",
                patchNumber: 2,
                sizeBytes: stagedArchive.patch.file.size,
                appliedDate: 8_000
            )
        )
    }

    func testRemoteSyncMyDocumentPatchReplayAppliesMultipleArchivesInOrder() throws {
        let container = try makeModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let documentID = UUID(uuidString: "a8240000-0000-0000-0000-000000000001")!
        let pageID = UUID(uuidString: "a8240000-0000-0000-0000-000000000011")!

        let document = MyDocument(id: documentID, name: "Batch Local", initials: "BATCH")
        let page = MyDocumentPage(id: pageID, title: "Batch Page", pageKey: "batch")
        let content = MyDocumentPageContent(pageId: pageID, content: "Before batch")
        document.pages = [page]
        page.document = document
        page.pageContent = content
        content.page = page
        modelContext.insert(document)
        modelContext.insert(page)
        modelContext.insert(content)
        try modelContext.save()

        RemoteSyncLogEntryStore(settingsStore: settingsStore).replaceEntries(
            [
                myDocumentLogEntry(
                    tableName: "MyDocument",
                    rowID: documentID,
                    type: .upsert,
                    timestamp: 1_000,
                    sourceDevice: "iphone"
                ),
                myDocumentLogEntry(
                    tableName: "MyDocumentPage",
                    rowID: pageID,
                    type: .upsert,
                    timestamp: 1_000,
                    sourceDevice: "iphone"
                ),
                myDocumentLogEntry(
                    tableName: "MyDocumentPageContent",
                    rowID: pageID,
                    type: .upsert,
                    timestamp: 1_000,
                    sourceDevice: "iphone"
                ),
            ],
            for: .myDocuments
        )

        let firstArchive = try makeStagedMyDocumentPatchArchive(
            sourceDevice: "pixel",
            patchNumber: 1,
            timestamp: 8_100,
            documents: [
                .init(id: documentID, name: "Batch Remote", initials: "BATCH")
            ],
            pages: [],
            pageContents: [],
            aiPageCacheEntries: [],
            logEntries: [
                myDocumentLogEntry(tableName: "MyDocument", rowID: documentID, type: .upsert, timestamp: 2_000)
            ]
        )
        let secondArchive = try makeStagedMyDocumentPatchArchive(
            sourceDevice: "pixel",
            patchNumber: 2,
            timestamp: 8_200,
            documents: [],
            pages: [],
            pageContents: [
                .init(pageId: pageID, content: "After batch")
            ],
            aiPageCacheEntries: [],
            logEntries: [
                myDocumentLogEntry(tableName: "MyDocumentPageContent", rowID: pageID, type: .upsert, timestamp: 3_000)
            ]
        )
        defer {
            try? FileManager.default.removeItem(at: firstArchive.archiveFileURL)
            try? FileManager.default.removeItem(at: secondArchive.archiveFileURL)
        }

        let report = try RemoteSyncMyDocumentPatchApplyService().applyPatchArchives(
            [firstArchive, secondArchive],
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(report.appliedPatchCount, 2)
        XCTAssertEqual(report.appliedLogEntryCount, 2)
        XCTAssertEqual(MyDocumentStore(modelContext: modelContext).document(initials: "BATCH")?.name, "Batch Remote")
        XCTAssertEqual(
            MyDocumentStore(modelContext: modelContext).rawContentPayload(bookInitials: "BATCH", pageKey: "batch")?.content,
            "After batch"
        )
        XCTAssertEqual(
            RemoteSyncPatchStatusStore(settingsStore: settingsStore).statuses(for: .myDocuments),
            [
                RemoteSyncPatchStatus(
                    sourceDevice: "pixel",
                    patchNumber: 1,
                    sizeBytes: firstArchive.patch.file.size,
                    appliedDate: 8_100
                ),
                RemoteSyncPatchStatus(
                    sourceDevice: "pixel",
                    patchNumber: 2,
                    sizeBytes: secondArchive.patch.file.size,
                    appliedDate: 8_200
                ),
            ]
        )
    }

    func testRemoteSyncMyDocumentPatchReplayRejectsMissingUpsertRowWithoutMutation() throws {
        let container = try makeModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let documentID = UUID(uuidString: "a8250000-0000-0000-0000-000000000001")!
        let missingDocumentID = UUID(uuidString: "a8250000-0000-0000-0000-000000000002")!

        modelContext.insert(MyDocument(id: documentID, name: "Existing", initials: "MISS"))
        try modelContext.save()

        let stagedArchive = try makeStagedMyDocumentPatchArchive(
            sourceDevice: "pixel",
            patchNumber: 3,
            timestamp: 8_500,
            documents: [],
            pages: [],
            pageContents: [],
            aiPageCacheEntries: [],
            logEntries: [
                myDocumentLogEntry(tableName: "MyDocument", rowID: missingDocumentID, type: .upsert)
            ]
        )
        defer { try? FileManager.default.removeItem(at: stagedArchive.archiveFileURL) }

        XCTAssertThrowsError(
            try RemoteSyncMyDocumentPatchApplyService().applyPatchArchives(
                [stagedArchive],
                modelContext: modelContext,
                settingsStore: settingsStore
            )
        ) { error in
            XCTAssertEqual(
                error as? RemoteSyncMyDocumentPatchApplyError,
                .missingPatchRow(table: "MyDocument", id: missingDocumentID)
            )
        }
        XCTAssertEqual(MyDocumentStore(modelContext: modelContext).document(initials: "MISS")?.name, "Existing")
        XCTAssertTrue(RemoteSyncPatchStatusStore(settingsStore: settingsStore).statuses(for: .myDocuments).isEmpty)
    }

    func testRemoteSyncMyDocumentPatchReplayRejectsInvalidLogEntryIdentifierWithoutMutation() throws {
        let container = try makeModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let documentID = UUID(uuidString: "a8260000-0000-0000-0000-000000000001")!

        modelContext.insert(MyDocument(id: documentID, name: "Existing", initials: "BADID"))
        try modelContext.save()

        let stagedArchive = try makeStagedMyDocumentPatchArchive(
            sourceDevice: "pixel",
            patchNumber: 4,
            timestamp: 8_600,
            documents: [],
            pages: [],
            pageContents: [],
            aiPageCacheEntries: [],
            logEntries: [
                RemoteSyncLogEntry(
                    tableName: "MyDocument",
                    entityID1: .text("not-a-uuid"),
                    entityID2: .text(""),
                    type: .upsert,
                    lastUpdated: 2_000,
                    sourceDevice: "pixel"
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: stagedArchive.archiveFileURL) }

        XCTAssertThrowsError(
            try RemoteSyncMyDocumentPatchApplyService().applyPatchArchives(
                [stagedArchive],
                modelContext: modelContext,
                settingsStore: settingsStore
            )
        ) { error in
            XCTAssertEqual(
                error as? RemoteSyncMyDocumentPatchApplyError,
                .invalidLogEntryIdentifier(table: "MyDocument", field: "entityId1")
            )
        }
        XCTAssertEqual(MyDocumentStore(modelContext: modelContext).document(initials: "BADID")?.name, "Existing")
        XCTAssertTrue(RemoteSyncPatchStatusStore(settingsStore: settingsStore).statuses(for: .myDocuments).isEmpty)
    }

    func testRemoteSyncMyDocumentPatchReplayAcceptsTextUUIDIdentifiers() throws {
        let container = try makeModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let documentID = UUID(uuidString: "a8270000-0000-0000-0000-000000000001")!

        modelContext.insert(MyDocument(id: documentID, name: "Text Local", initials: "TXTID"))
        try modelContext.save()

        RemoteSyncLogEntryStore(settingsStore: settingsStore).replaceEntries(
            [
                myDocumentLogEntry(
                    tableName: "MyDocument",
                    rowID: documentID,
                    type: .upsert,
                    timestamp: 1_000,
                    sourceDevice: "iphone"
                )
            ],
            for: .myDocuments
        )
        let stagedArchive = try makeStagedMyDocumentPatchArchive(
            sourceDevice: "pixel",
            patchNumber: 5,
            timestamp: 8_700,
            documents: [
                .init(id: documentID, name: "Text Remote", initials: "TXTID")
            ],
            pages: [],
            pageContents: [],
            aiPageCacheEntries: [],
            logEntries: [
                RemoteSyncLogEntry(
                    tableName: "MyDocument",
                    entityID1: .text(documentID.uuidString),
                    entityID2: .text(""),
                    type: .upsert,
                    lastUpdated: 2_000,
                    sourceDevice: "pixel"
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: stagedArchive.archiveFileURL) }

        let report = try RemoteSyncMyDocumentPatchApplyService().applyPatchArchives(
            [stagedArchive],
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(report.appliedLogEntryCount, 1)
        XCTAssertEqual(MyDocumentStore(modelContext: modelContext).document(initials: "TXTID")?.name, "Text Remote")
        XCTAssertEqual(
            RemoteSyncLogEntryStore(settingsStore: settingsStore).entries(for: .myDocuments),
            [
                myDocumentLogEntry(
                    tableName: "MyDocument",
                    rowID: documentID,
                    type: .upsert,
                    timestamp: 2_000,
                    sourceDevice: "pixel"
                )
            ]
        )
    }

    func testRemoteSyncMyDocumentPatchReplaySkipsOlderBlobPatchAgainstTextUUIDBaseline() throws {
        let container = try makeModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let documentID = UUID(uuidString: "a8280000-0000-0000-0000-000000000001")!

        modelContext.insert(MyDocument(id: documentID, name: "Text Baseline Local", initials: "TXTBLOB"))
        try modelContext.save()

        RemoteSyncLogEntryStore(settingsStore: settingsStore).replaceEntries(
            [
                RemoteSyncLogEntry(
                    tableName: "MyDocument",
                    entityID1: .text(documentID.uuidString),
                    entityID2: .text(""),
                    type: .upsert,
                    lastUpdated: 5_000,
                    sourceDevice: "iphone"
                )
            ],
            for: .myDocuments
        )
        let stagedArchive = try makeStagedMyDocumentPatchArchive(
            sourceDevice: "pixel",
            patchNumber: 6,
            timestamp: 8_800,
            documents: [
                .init(id: documentID, name: "Older Blob Remote", initials: "TXTBLOB")
            ],
            pages: [],
            pageContents: [],
            aiPageCacheEntries: [],
            logEntries: [
                myDocumentLogEntry(
                    tableName: "MyDocument",
                    rowID: documentID,
                    type: .upsert,
                    timestamp: 1_000,
                    sourceDevice: "pixel"
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: stagedArchive.archiveFileURL) }

        let report = try RemoteSyncMyDocumentPatchApplyService().applyPatchArchives(
            [stagedArchive],
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(report.appliedLogEntryCount, 0)
        XCTAssertEqual(report.skippedLogEntryCount, 1)
        XCTAssertEqual(
            MyDocumentStore(modelContext: modelContext).document(initials: "TXTBLOB")?.name,
            "Text Baseline Local"
        )
        XCTAssertEqual(
            RemoteSyncLogEntryStore(settingsStore: settingsStore).entries(for: .myDocuments),
            [
                myDocumentLogEntry(
                    tableName: "MyDocument",
                    rowID: documentID,
                    type: .upsert,
                    timestamp: 5_000,
                    sourceDevice: "iphone"
                )
            ]
        )
    }

    func testRemoteSyncSynchronizationServiceReplaysRemoteMyDocumentPatch() async throws {
        let container = try makeModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let syncFolderID = "/org.andbible.ios-sync-mydocuments"
        let localDeviceFolderID = "\(syncFolderID)/ios-device"
        let remoteDeviceFolderID = "\(syncFolderID)/pixel"

        stateStore.setBootstrapState(
            RemoteSyncBootstrapState(
                syncFolderID: syncFolderID,
                deviceFolderID: localDeviceFolderID,
                secretFileName: "device-known-ios-device-secret"
            ),
            for: .myDocuments
        )

        let documentID = UUID(uuidString: "a8300000-0000-0000-0000-000000000001")!
        let pageID = UUID(uuidString: "a8300000-0000-0000-0000-000000000011")!
        let document = MyDocument(id: documentID, name: "Sync Replay", initials: "REPLAY")
        let page = MyDocumentPage(id: pageID, title: "Replay Page", pageKey: "replay")
        let content = MyDocumentPageContent(pageId: pageID, content: "Before replay")
        document.pages = [page]
        page.document = document
        page.pageContent = content
        content.page = page
        modelContext.insert(document)
        modelContext.insert(page)
        modelContext.insert(content)
        try modelContext.save()

        RemoteSyncLogEntryStore(settingsStore: settingsStore).replaceEntries(
            [
                myDocumentLogEntry(
                    tableName: "MyDocument",
                    rowID: documentID,
                    type: .upsert,
                    timestamp: 1_000,
                    sourceDevice: "iphone"
                ),
                myDocumentLogEntry(
                    tableName: "MyDocumentPage",
                    rowID: pageID,
                    type: .upsert,
                    timestamp: 1_000,
                    sourceDevice: "iphone"
                ),
                myDocumentLogEntry(
                    tableName: "MyDocumentPageContent",
                    rowID: pageID,
                    type: .upsert,
                    timestamp: 1_000,
                    sourceDevice: "iphone"
                ),
            ],
            for: .myDocuments
        )

        let stagedArchive = try makeStagedMyDocumentPatchArchive(
            sourceDevice: "pixel",
            patchNumber: 1,
            timestamp: 7_500,
            documents: [],
            pages: [],
            pageContents: [
                .init(pageId: pageID, content: "After replay")
            ],
            aiPageCacheEntries: [],
            logEntries: [
                myDocumentLogEntry(tableName: "MyDocumentPageContent", rowID: pageID, type: .upsert)
            ]
        )
        defer { try? FileManager.default.removeItem(at: stagedArchive.archiveFileURL) }
        let archiveData = try Data(contentsOf: stagedArchive.archiveFileURL)
        let remoteDeviceFolder = RemoteSyncFile(
            id: remoteDeviceFolderID,
            name: "pixel",
            size: 0,
            timestamp: 7_400,
            parentID: syncFolderID,
            mimeType: NextCloudSyncAdapter.folderMimeType
        )
        let remotePatchFile = RemoteSyncFile(
            id: "\(remoteDeviceFolderID)/1.4.sqlite3.gz",
            name: "1.4.sqlite3.gz",
            size: Int64(archiveData.count),
            timestamp: 7_500,
            parentID: remoteDeviceFolderID,
            mimeType: NextCloudSyncAdapter.gzipMimeType
        )
        let adapter = MyDocumentMockRemoteSyncAdapter()
        await adapter.setKnownResponse(
            true,
            forSyncFolderID: syncFolderID,
            secretFileName: "device-known-ios-device-secret"
        )
        await adapter.setListedFiles([remoteDeviceFolder], forParentID: syncFolderID)
        await adapter.setListedFiles([remotePatchFile], forParentID: remoteDeviceFolderID)
        await adapter.setDownloadData(archiveData, forID: remotePatchFile.id)
        let service = RemoteSyncSynchronizationService(
            adapter: adapter,
            bundleIdentifier: "org.andbible.ios",
            deviceIdentifier: "ios-device",
            nowProvider: { 7_600 }
        )

        let outcome = try await service.synchronize(
            .myDocuments,
            modelContext: modelContext,
            settingsStore: settingsStore,
            currentSchemaVersion: RemoteSyncMyDocumentRestoreService.supportedAndroidSchemaVersion
        )

        guard case .synchronized(let report) = outcome else {
            return XCTFail("Expected synchronized outcome")
        }
        XCTAssertEqual(report.category, .myDocuments)
        XCTAssertEqual(report.discoveredPatchCount, 1)
        XCTAssertNil(report.patchUploadReport)
        XCTAssertEqual(report.lastPatchWritten, nil)
        XCTAssertEqual(report.lastSynchronized, 7_600)
        guard case .myDocuments(let replayReport)? = report.patchReplayReport else {
            return XCTFail("Expected My Documents replay report")
        }
        XCTAssertEqual(replayReport.appliedPatchCount, 1)
        XCTAssertEqual(replayReport.appliedLogEntryCount, 1)
        XCTAssertEqual(replayReport.skippedLogEntryCount, 0)
        XCTAssertEqual(
            MyDocumentStore(modelContext: modelContext).rawContentPayload(bookInitials: "REPLAY", pageKey: "replay")?.content,
            "After replay"
        )
        XCTAssertEqual(
            RemoteSyncPatchStatusStore(settingsStore: settingsStore).status(
                for: .myDocuments,
                sourceDevice: "pixel",
                patchNumber: 1
            )?.appliedDate,
            7_500
        )
    }

    func testRemoteSyncMyDocumentPatchUploadWritesAndUploadsSparsePatch() async throws {
        let container = try makeModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let snapshotService = RemoteSyncMyDocumentSnapshotService()
        let metadataRestoreService = RemoteSyncInitialBackupMetadataRestoreService()
        let restoreService = RemoteSyncMyDocumentRestoreService()

        let existingDocumentID = UUID(uuidString: "a7100000-0000-0000-0000-000000000001")!
        let existingPageID = UUID(uuidString: "a7100000-0000-0000-0000-000000000011")!
        let existingPromptID = UUID(uuidString: "a7100000-0000-0000-0000-000000000021")!
        let newDocumentID = UUID(uuidString: "a7100000-0000-0000-0000-000000000002")!
        let newPageID = UUID(uuidString: "a7100000-0000-0000-0000-000000000012")!
        let newPromptID = UUID(uuidString: "a7100000-0000-0000-0000-000000000022")!
        let createdAt = Date(timeIntervalSince1970: 1_735_689_600)
        let updatedAt = Date(timeIntervalSince1970: 1_735_689_660)

        let existingDocument = MyDocument(
            id: existingDocumentID,
            name: "Existing",
            initials: "EXIST",
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        let existingPage = MyDocumentPage(
            id: existingPageID,
            title: "Existing Page",
            pageKey: "existing",
            contentType: .markdown,
            createdAt: createdAt,
            updatedAt: updatedAt,
            sourcePromptId: existingPromptID,
            languageCode: "en"
        )
        let existingContent = MyDocumentPageContent(pageId: existingPageID, content: "Original content")
        let existingCacheEntry = AiPageCacheEntry(
            pageId: existingPageID,
            sourcePromptId: existingPromptID,
            contextHash: "old-context",
            sourceBookKey: "John.1"
        )
        existingDocument.pages = [existingPage]
        existingPage.document = existingDocument
        existingPage.pageContent = existingContent
        existingContent.page = existingPage
        existingPage.aiPageCacheEntries = [existingCacheEntry]
        existingCacheEntry.page = existingPage
        modelContext.insert(existingDocument)
        modelContext.insert(existingPage)
        modelContext.insert(existingContent)
        modelContext.insert(existingCacheEntry)
        try modelContext.save()

        logEntryStore.replaceEntries(
            myDocumentLogEntries(
                documentIDs: [existingDocumentID],
                pageIDs: [existingPageID],
                timestamp: 1_000,
                sourceDevice: "pixel"
            ),
            for: .myDocuments
        )
        snapshotService.refreshBaselineFingerprints(
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        existingContent.content = "Edited content only"
        existingCacheEntry.contextHash = "updated-context"
        let newDocument = MyDocument(
            id: newDocumentID,
            name: "New",
            documentDescription: "Created locally",
            initials: "NEWDOC",
            orderNumber: 1,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        let newPage = MyDocumentPage(
            id: newPageID,
            title: "New Page",
            pageKey: "new",
            contentType: .html,
            orderNumber: 1,
            createdAt: createdAt,
            updatedAt: updatedAt,
            sourcePromptId: newPromptID,
            languageCode: "en"
        )
        let newContent = MyDocumentPageContent(pageId: newPageID, content: "<p>New</p>")
        let newCacheEntry = AiPageCacheEntry(
            pageId: newPageID,
            sourcePromptId: newPromptID,
            sourceContext: #"{"osisRef":"Rom.8"}"#,
            kjvOrdinalStart: 28_000,
            kjvOrdinalEnd: 28_001,
            contextHash: "new-context",
            usedWriteTools: true,
            sourceModelName: "gpt-test",
            sourceBookInitials: "KJV",
            sourceBookKey: "Rom.8"
        )
        newDocument.pages = [newPage]
        newPage.document = newDocument
        newPage.pageContent = newContent
        newContent.page = newPage
        newPage.aiPageCacheEntries = [newCacheEntry]
        newCacheEntry.page = newPage
        modelContext.insert(newDocument)
        modelContext.insert(newPage)
        modelContext.insert(newContent)
        modelContext.insert(newCacheEntry)
        try modelContext.save()

        let adapter = MyDocumentMockRemoteSyncAdapter()
        await adapter.enqueueUploadResult(
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-mydocuments/ios-device/1.4.sqlite3.gz",
                name: "1.4.sqlite3.gz",
                size: 0,
                timestamp: 3_000,
                parentID: "/org.andbible.ios-sync-mydocuments/ios-device",
                mimeType: NextCloudSyncAdapter.gzipMimeType
            )
        )
        let service = RemoteSyncMyDocumentPatchUploadService(
            adapter: adapter,
            nowProvider: { 3_000 }
        )

        let report = try await service.uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/org.andbible.ios-sync-mydocuments/ios-device"),
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let unwrappedReport = try XCTUnwrap(report)
        XCTAssertEqual(unwrappedReport.patchNumber, 1)
        XCTAssertEqual(unwrappedReport.upsertedDocumentCount, 1)
        XCTAssertEqual(unwrappedReport.upsertedPageCount, 1)
        XCTAssertEqual(unwrappedReport.upsertedPageContentCount, 2)
        XCTAssertEqual(unwrappedReport.upsertedAiPageCacheEntryCount, 2)
        XCTAssertEqual(unwrappedReport.deletedRowCount, 0)
        XCTAssertEqual(unwrappedReport.logEntryCount, 6)
        XCTAssertEqual(unwrappedReport.lastUpdated, 3_000)

        let uploadedFiles = await adapter.uploadedFilesSnapshot()
        let uploadedFile = try XCTUnwrap(uploadedFiles.first)
        XCTAssertEqual(uploadedFile.name, "1.4.sqlite3.gz")
        XCTAssertEqual(uploadedFile.parentID, "/org.andbible.ios-sync-mydocuments/ios-device")
        XCTAssertEqual(uploadedFile.contentType, NextCloudSyncAdapter.gzipMimeType)
        let databaseURL = try writeUploadedMyDocumentDatabase(uploadedFile.data)
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        XCTAssertEqual(try sqliteUserVersion(at: databaseURL), RemoteSyncMyDocumentRestoreService.supportedAndroidSchemaVersion)
        XCTAssertEqual(try sqliteRoomIdentityHash(at: databaseURL), "3f0946602099d896c8d47129233c1794")
        let metadataSnapshot = try metadataRestoreService.readSnapshot(from: databaseURL)
        XCTAssertEqual(metadataSnapshot.logEntries.map(\.type), Array(repeating: .upsert, count: 6))
        XCTAssertEqual(Set(metadataSnapshot.logEntries.map(\.sourceDevice)), ["ios-device"])
        XCTAssertEqual(
            metadataSnapshot.logEntries.map(\.entityID2),
            Array(repeating: RemoteSyncMyDocumentSnapshotService.emptySecondaryEntityID, count: 6)
        )
        XCTAssertEqual(
            Set(metadataSnapshot.logEntries.map(\.tableName)),
            ["AiPageCacheEntry", "MyDocument", "MyDocumentPage", "MyDocumentPageContent"]
        )

        let patchSnapshot = try restoreService.readSnapshot(from: databaseURL)
        XCTAssertEqual(patchSnapshot.documents.map(\.id), [newDocumentID])
        XCTAssertEqual(patchSnapshot.pages.map(\.id), [newPageID])
        XCTAssertEqual(
            patchSnapshot.pageContents.sorted { $0.pageId.uuidString < $1.pageId.uuidString },
            [
                .init(pageId: existingPageID, content: "Edited content only"),
                .init(pageId: newPageID, content: "<p>New</p>"),
            ]
        )
        XCTAssertEqual(Set(patchSnapshot.aiPageCacheEntries.map(\.pageId)), [existingPageID, newPageID])
        XCTAssertEqual(patchSnapshot.aiPageCacheEntries.first(where: { $0.pageId == newPageID })?.sourceBookKey, "Rom.8")

        XCTAssertEqual(
            patchStatusStore.statuses(for: .myDocuments),
            [
                RemoteSyncPatchStatus(
                    sourceDevice: "ios-device",
                    patchNumber: 1,
                    sizeBytes: unwrappedReport.uploadedFile.size,
                    appliedDate: 3_000
                )
            ]
        )
        XCTAssertEqual(stateStore.progressState(for: .myDocuments).lastPatchWritten, 3_000)
        XCTAssertEqual(logEntryStore.entries(for: .myDocuments).count, 8)

        let currentSnapshot = snapshotService.snapshotCurrentState(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let existingContentKey = logEntryStore.key(
            for: .myDocuments,
            tableName: "MyDocumentPageContent",
            entityID1: .blob(uuidBlob(existingPageID)),
            entityID2: .text("")
        )
        XCTAssertEqual(
            RemoteSyncRowFingerprintStore(settingsStore: settingsStore).fingerprint(
                forLogKey: existingContentKey,
                category: .myDocuments
            ),
            currentSnapshot.fingerprintsByKey[existingContentKey]
        )
    }

    func testRemoteSyncMyDocumentPatchUploadReturnsNilWhenStateMatchesBaseline() async throws {
        let container = try makeModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let documentID = UUID(uuidString: "a7200000-0000-0000-0000-000000000001")!
        let pageID = UUID(uuidString: "a7200000-0000-0000-0000-000000000011")!
        let promptID = UUID(uuidString: "a7200000-0000-0000-0000-000000000021")!

        let document = MyDocument(id: documentID, name: "Idle", initials: "IDLE")
        let page = MyDocumentPage(id: pageID, title: "Idle Page", pageKey: "idle", sourcePromptId: promptID)
        let content = MyDocumentPageContent(pageId: pageID, content: "Unchanged")
        let cacheEntry = AiPageCacheEntry(pageId: pageID, sourcePromptId: promptID, contextHash: "unchanged")
        document.pages = [page]
        page.document = document
        page.pageContent = content
        content.page = page
        page.aiPageCacheEntries = [cacheEntry]
        cacheEntry.page = page
        modelContext.insert(document)
        modelContext.insert(page)
        modelContext.insert(content)
        modelContext.insert(cacheEntry)
        try modelContext.save()

        RemoteSyncLogEntryStore(settingsStore: settingsStore).replaceEntries(
            myDocumentLogEntries(
                documentIDs: [documentID],
                pageIDs: [pageID],
                timestamp: 1_000,
                sourceDevice: "pixel"
            ),
            for: .myDocuments
        )
        RemoteSyncMyDocumentSnapshotService().refreshBaselineFingerprints(
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let adapter = MyDocumentMockRemoteSyncAdapter()
        let service = RemoteSyncMyDocumentPatchUploadService(
            adapter: adapter,
            nowProvider: { 4_000 }
        )

        let report = try await service.uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/org.andbible.ios-sync-mydocuments/ios-device"),
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertNil(report)
        let uploadedFiles = await adapter.uploadedFilesSnapshot()
        XCTAssertTrue(uploadedFiles.isEmpty)
    }

    func testRemoteSyncMyDocumentPatchUploadUploadsRowsWithMissingFingerprintBaseline() async throws {
        let container = try makeModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let documentID = UUID(uuidString: "a7250000-0000-0000-0000-000000000001")!
        let document = MyDocument(id: documentID, name: "Migrated", initials: "MIG")
        modelContext.insert(document)
        try modelContext.save()

        RemoteSyncLogEntryStore(settingsStore: settingsStore).replaceEntries(
            myDocumentLogEntries(
                documentIDs: [documentID],
                pageIDs: [],
                timestamp: 1_000,
                sourceDevice: "pixel"
            ),
            for: .myDocuments
        )

        let adapter = MyDocumentMockRemoteSyncAdapter()
        await adapter.enqueueUploadResult(
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-mydocuments/ios-device/1.4.sqlite3.gz",
                name: "1.4.sqlite3.gz",
                size: 0,
                timestamp: 4_500,
                parentID: "/org.andbible.ios-sync-mydocuments/ios-device",
                mimeType: NextCloudSyncAdapter.gzipMimeType
            )
        )
        let service = RemoteSyncMyDocumentPatchUploadService(
            adapter: adapter,
            nowProvider: { 4_500 }
        )

        let report = try await service.uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/org.andbible.ios-sync-mydocuments/ios-device"),
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let unwrappedReport = try XCTUnwrap(report)
        XCTAssertEqual(unwrappedReport.upsertedDocumentCount, 1)
        XCTAssertEqual(unwrappedReport.logEntryCount, 1)

        let uploadedFiles = await adapter.uploadedFilesSnapshot()
        let uploadedFile = try XCTUnwrap(uploadedFiles.first)
        let databaseURL = try writeUploadedMyDocumentDatabase(uploadedFile.data)
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let patchSnapshot = try RemoteSyncMyDocumentRestoreService().readSnapshot(from: databaseURL)
        XCTAssertEqual(patchSnapshot.documents.map(\.id), [documentID])
    }

    func testRemoteSyncMyDocumentPatchUploadRejectsMissingDeviceFolder() async throws {
        let container = try makeModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let service = RemoteSyncMyDocumentPatchUploadService(
            adapter: MyDocumentMockRemoteSyncAdapter(),
            nowProvider: { 4_750 }
        )

        do {
            _ = try await service.uploadPendingPatch(
                bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "   "),
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            XCTFail("Expected missing device folder error")
        } catch {
            XCTAssertEqual(error as? RemoteSyncMyDocumentPatchUploadError, .missingDeviceFolderID)
        }
    }

    func testRemoteSyncMyDocumentPatchUploadDetectsDeletesAfterBaselineRefresh() async throws {
        let container = try makeModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let metadataRestoreService = RemoteSyncInitialBackupMetadataRestoreService()
        let documentID = UUID(uuidString: "a7300000-0000-0000-0000-000000000001")!
        let pageID = UUID(uuidString: "a7300000-0000-0000-0000-000000000011")!
        let promptID = UUID(uuidString: "a7300000-0000-0000-0000-000000000021")!

        let document = MyDocument(id: documentID, name: "Delete", initials: "DEL")
        let page = MyDocumentPage(id: pageID, title: "Delete Page", pageKey: "delete", sourcePromptId: promptID)
        let content = MyDocumentPageContent(pageId: pageID, content: "Delete me")
        let cacheEntry = AiPageCacheEntry(pageId: pageID, sourcePromptId: promptID, contextHash: "delete")
        document.pages = [page]
        page.document = document
        page.pageContent = content
        content.page = page
        page.aiPageCacheEntries = [cacheEntry]
        cacheEntry.page = page
        modelContext.insert(document)
        modelContext.insert(page)
        modelContext.insert(content)
        modelContext.insert(cacheEntry)
        try modelContext.save()

        RemoteSyncLogEntryStore(settingsStore: settingsStore).replaceEntries(
            myDocumentLogEntries(
                documentIDs: [documentID],
                pageIDs: [pageID],
                timestamp: 1_000,
                sourceDevice: "pixel"
            ),
            for: .myDocuments
        )
        RemoteSyncMyDocumentSnapshotService().refreshBaselineFingerprints(
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        modelContext.delete(document)
        try modelContext.save()

        let adapter = MyDocumentMockRemoteSyncAdapter()
        await adapter.enqueueUploadResult(
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-mydocuments/ios-device/1.4.sqlite3.gz",
                name: "1.4.sqlite3.gz",
                size: 0,
                timestamp: 5_000,
                parentID: "/org.andbible.ios-sync-mydocuments/ios-device",
                mimeType: NextCloudSyncAdapter.gzipMimeType
            )
        )
        let service = RemoteSyncMyDocumentPatchUploadService(
            adapter: adapter,
            nowProvider: { 5_000 }
        )

        let report = try await service.uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/org.andbible.ios-sync-mydocuments/ios-device"),
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let unwrappedReport = try XCTUnwrap(report)
        XCTAssertEqual(unwrappedReport.upsertedDocumentCount, 0)
        XCTAssertEqual(unwrappedReport.upsertedPageCount, 0)
        XCTAssertEqual(unwrappedReport.upsertedPageContentCount, 0)
        XCTAssertEqual(unwrappedReport.upsertedAiPageCacheEntryCount, 0)
        XCTAssertEqual(unwrappedReport.deletedRowCount, 4)
        XCTAssertEqual(unwrappedReport.logEntryCount, 4)

        let uploadedFiles = await adapter.uploadedFilesSnapshot()
        let uploadedFile = try XCTUnwrap(uploadedFiles.first)
        let databaseURL = try writeUploadedMyDocumentDatabase(uploadedFile.data)
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let metadataSnapshot = try metadataRestoreService.readSnapshot(from: databaseURL)
        XCTAssertEqual(metadataSnapshot.logEntries.map(\.type), Array(repeating: .delete, count: 4))
        XCTAssertEqual(
            Set(metadataSnapshot.logEntries.map(\.tableName)),
            ["AiPageCacheEntry", "MyDocument", "MyDocumentPage", "MyDocumentPageContent"]
        )
        XCTAssertEqual(try sqliteCount(tableName: "MyDocument", databaseURL: databaseURL), 0)
        XCTAssertEqual(try sqliteCount(tableName: "MyDocumentPageContent", databaseURL: databaseURL), 0)
        XCTAssertEqual(try sqliteCount(tableName: "AiPageCacheEntry", databaseURL: databaseURL), 0)
    }

    func testRemoteSyncSynchronizationServiceUploadsLocalMyDocumentChangesWhenNoRemotePatchesExist() async throws {
        let container = try makeModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let snapshotService = RemoteSyncMyDocumentSnapshotService()
        let syncFolderID = "/org.andbible.ios-sync-mydocuments"
        let deviceFolderID = "/org.andbible.ios-sync-mydocuments/ios-device"

        stateStore.setBootstrapState(
            RemoteSyncBootstrapState(
                syncFolderID: syncFolderID,
                deviceFolderID: deviceFolderID,
                secretFileName: "device-known-ios-device-secret"
            ),
            for: .myDocuments
        )

        let documentID = UUID(uuidString: "a7400000-0000-0000-0000-000000000001")!
        let pageID = UUID(uuidString: "a7400000-0000-0000-0000-000000000011")!
        let promptID = UUID(uuidString: "a7400000-0000-0000-0000-000000000021")!
        let document = MyDocument(id: documentID, name: "Sync", initials: "SYNC")
        let page = MyDocumentPage(id: pageID, title: "Sync Page", pageKey: "sync", sourcePromptId: promptID)
        let content = MyDocumentPageContent(pageId: pageID, content: "Sync")
        let cacheEntry = AiPageCacheEntry(pageId: pageID, sourcePromptId: promptID)
        document.pages = [page]
        page.document = document
        page.pageContent = content
        content.page = page
        page.aiPageCacheEntries = [cacheEntry]
        cacheEntry.page = page
        modelContext.insert(document)
        modelContext.insert(page)
        modelContext.insert(content)
        modelContext.insert(cacheEntry)
        try modelContext.save()

        logEntryStore.replaceEntries(
            myDocumentLogEntries(
                documentIDs: [documentID],
                pageIDs: [pageID],
                timestamp: 1_000,
                sourceDevice: "pixel"
            ),
            for: .myDocuments
        )
        snapshotService.refreshBaselineFingerprints(
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        document.name = "Sync Updated"
        try modelContext.save()

        let adapter = MyDocumentMockRemoteSyncAdapter()
        await adapter.setKnownResponse(
            true,
            forSyncFolderID: syncFolderID,
            secretFileName: "device-known-ios-device-secret"
        )
        await adapter.enqueueUploadResult(
            RemoteSyncFile(
                id: "\(deviceFolderID)/1.4.sqlite3.gz",
                name: "1.4.sqlite3.gz",
                size: 0,
                timestamp: 6_000,
                parentID: deviceFolderID,
                mimeType: NextCloudSyncAdapter.gzipMimeType
            )
        )

        let service = RemoteSyncSynchronizationService(
            adapter: adapter,
            bundleIdentifier: "org.andbible.ios",
            deviceIdentifier: "ios-device",
            nowProvider: { 6_000 }
        )

        let outcome = try await service.synchronize(
            .myDocuments,
            modelContext: modelContext,
            settingsStore: settingsStore,
            currentSchemaVersion: RemoteSyncMyDocumentRestoreService.supportedAndroidSchemaVersion
        )

        guard case .synchronized(let report) = outcome else {
            return XCTFail("Expected synchronized outcome")
        }
        XCTAssertEqual(report.category, .myDocuments)
        XCTAssertNil(report.initialRestoreReport)
        XCTAssertNil(report.patchReplayReport)
        XCTAssertEqual(report.discoveredPatchCount, 0)
        XCTAssertEqual(report.lastPatchWritten, 6_000)
        XCTAssertEqual(report.lastSynchronized, 6_000)

        guard case .myDocuments(let uploadReport)? = report.patchUploadReport else {
            return XCTFail("Expected My Documents patch upload report")
        }
        XCTAssertEqual(uploadReport.patchNumber, 1)
        XCTAssertEqual(uploadReport.upsertedDocumentCount, 1)
        XCTAssertEqual(uploadReport.upsertedPageCount, 0)
        XCTAssertEqual(uploadReport.upsertedPageContentCount, 0)
        XCTAssertEqual(uploadReport.upsertedAiPageCacheEntryCount, 0)
        XCTAssertEqual(uploadReport.deletedRowCount, 0)
        XCTAssertEqual(uploadReport.logEntryCount, 1)
        XCTAssertEqual(uploadReport.lastUpdated, 6_000)
        XCTAssertEqual(uploadReport.uploadedFile.name, "1.4.sqlite3.gz")
        XCTAssertEqual(uploadReport.uploadedFile.parentID, deviceFolderID)
        XCTAssertEqual(
            patchStatusStore.statuses(for: .myDocuments),
            [
                RemoteSyncPatchStatus(
                    sourceDevice: "ios-device",
                    patchNumber: 1,
                    sizeBytes: uploadReport.uploadedFile.size,
                    appliedDate: 6_000
                )
            ]
        )
    }

    private func makeModelContainer() throws -> ModelContainer {
        let schema = Schema([
            MyDocument.self,
            MyDocumentPage.self,
            MyDocumentPageContent.self,
            AiPageCacheEntry.self,
            Setting.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func makeStagedMyDocumentPatchArchive(
        sourceDevice: String,
        patchNumber: Int64,
        timestamp: Int64,
        documents: [AndroidMyDocumentRow],
        pages: [AndroidMyDocumentPageRow],
        pageContents: [AndroidMyDocumentPageContentRow],
        aiPageCacheEntries: [AndroidAiPageCacheEntryRow],
        logEntries: [RemoteSyncLogEntry]
    ) throws -> RemoteSyncStagedPatchArchive {
        let databaseURL = try makeAndroidMyDocumentsDatabase(
            documents: documents,
            pages: pages,
            pageContents: pageContents,
            aiPageCacheEntries: aiPageCacheEntries,
            logEntries: logEntries
        )
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let archiveData = try RemoteSyncArchiveStagingService.gzip(Data(contentsOf: databaseURL))
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("android-mydocuments-patch-\(UUID().uuidString).sqlite3.gz")
        try archiveData.write(to: archiveURL, options: .atomic)

        let parentID = "/org.andbible.ios-sync-mydocuments/\(sourceDevice)"
        return RemoteSyncStagedPatchArchive(
            patch: RemoteSyncDiscoveredPatch(
                sourceDevice: sourceDevice,
                patchNumber: patchNumber,
                schemaVersion: RemoteSyncMyDocumentRestoreService.supportedAndroidSchemaVersion,
                file: RemoteSyncFile(
                    id: "\(parentID)/\(patchNumber).\(RemoteSyncMyDocumentRestoreService.supportedAndroidSchemaVersion).sqlite3.gz",
                    name: "\(patchNumber).\(RemoteSyncMyDocumentRestoreService.supportedAndroidSchemaVersion).sqlite3.gz",
                    size: Int64(archiveData.count),
                    timestamp: timestamp,
                    parentID: parentID,
                    mimeType: NextCloudSyncAdapter.gzipMimeType
                )
            ),
            archiveFileURL: archiveURL
        )
    }

    private func makeAndroidMyDocumentsDatabase(
        documents: [AndroidMyDocumentRow],
        pages: [AndroidMyDocumentPageRow],
        pageContents: [AndroidMyDocumentPageContentRow],
        aiPageCacheEntries: [AndroidAiPageCacheEntryRow],
        logEntries: [RemoteSyncLogEntry] = [],
        syncStatuses: [RemoteSyncPatchStatus] = [],
        schemaVersion: Int = RemoteSyncMyDocumentRestoreService.supportedAndroidSchemaVersion
    ) throws -> URL {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("android-mydocuments-\(UUID().uuidString).sqlite3")

        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK, let db else {
            XCTFail("Failed to open temporary Android My Documents database")
            throw RemoteSyncMyDocumentRestoreError.invalidSQLiteDatabase
        }
        defer { XCTAssertEqual(sqlite3_close(db), SQLITE_OK) }

        let schemaSQL = """
        PRAGMA user_version = \(schemaVersion);
        CREATE TABLE MyDocument (
            id BLOB NOT NULL PRIMARY KEY,
            name TEXT NOT NULL,
            description TEXT,
            initials TEXT NOT NULL,
            orderNumber INTEGER NOT NULL,
            createdAt INTEGER NOT NULL,
            updatedAt INTEGER NOT NULL,
            sourcePromptId BLOB
        );
        CREATE TABLE MyDocumentPage (
            id BLOB NOT NULL PRIMARY KEY,
            documentId BLOB NOT NULL,
            title TEXT NOT NULL,
            pageKey TEXT NOT NULL,
            contentType TEXT NOT NULL,
            orderNumber INTEGER NOT NULL,
            createdAt INTEGER NOT NULL,
            updatedAt INTEGER NOT NULL,
            sourcePromptId BLOB,
            languageCode TEXT
        );
        CREATE TABLE MyDocumentPageContent (
            pageId BLOB NOT NULL PRIMARY KEY,
            content TEXT NOT NULL
        );
        CREATE TABLE AiPageCacheEntry (
            pageId BLOB NOT NULL PRIMARY KEY,
            sourcePromptId BLOB NOT NULL,
            sourceContext TEXT,
            kjvOrdinalStart INTEGER,
            kjvOrdinalEnd INTEGER,
            contextHash TEXT,
            usedWriteTools INTEGER NOT NULL,
            sourceModelName TEXT,
            sourceBookInitials TEXT,
            sourceBookKey TEXT
        );
        CREATE TABLE LogEntry (
            tableName TEXT NOT NULL,
            entityId1 BLOB NOT NULL,
            entityId2 BLOB NOT NULL DEFAULT '',
            type TEXT NOT NULL,
            lastUpdated INTEGER NOT NULL,
            sourceDevice TEXT NOT NULL
        );
        CREATE TABLE SyncStatus (
            sourceDevice TEXT NOT NULL,
            patchNumber INTEGER NOT NULL,
            sizeBytes INTEGER NOT NULL,
            appliedDate INTEGER NOT NULL,
            PRIMARY KEY(sourceDevice, patchNumber)
        );
        """
        XCTAssertEqual(sqlite3_exec(db, schemaSQL, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))

        for document in documents {
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    db,
                    "INSERT INTO MyDocument (id, name, description, initials, orderNumber, createdAt, updatedAt, sourcePromptId) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                    -1,
                    &statement,
                    nil
                ),
                SQLITE_OK
            )
            bindUUIDBlob(document.id, to: statement, index: 1)
            sqlite3_bind_text(statement, 2, document.name, -1, myDocumentRestoreSQLiteTransient)
            bindOptionalText(document.documentDescription, to: statement, index: 3)
            sqlite3_bind_text(statement, 4, document.initials, -1, myDocumentRestoreSQLiteTransient)
            sqlite3_bind_int(statement, 5, Int32(document.orderNumber))
            bindDate(document.createdAt, to: statement, index: 6)
            bindDate(document.updatedAt, to: statement, index: 7)
            bindOptionalUUIDBlob(document.sourcePromptId, to: statement, index: 8)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }

        for page in pages {
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    db,
                    "INSERT INTO MyDocumentPage (id, documentId, title, pageKey, contentType, orderNumber, createdAt, updatedAt, sourcePromptId, languageCode) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    -1,
                    &statement,
                    nil
                ),
                SQLITE_OK
            )
            bindUUIDBlob(page.id, to: statement, index: 1)
            bindUUIDBlob(page.documentId, to: statement, index: 2)
            sqlite3_bind_text(statement, 3, page.title, -1, myDocumentRestoreSQLiteTransient)
            sqlite3_bind_text(statement, 4, page.pageKey, -1, myDocumentRestoreSQLiteTransient)
            sqlite3_bind_text(statement, 5, page.contentTypeRawValue ?? page.contentType.rawValue, -1, myDocumentRestoreSQLiteTransient)
            sqlite3_bind_int(statement, 6, Int32(page.orderNumber))
            bindDate(page.createdAt, to: statement, index: 7)
            bindDate(page.updatedAt, to: statement, index: 8)
            bindOptionalUUIDBlob(page.sourcePromptId, to: statement, index: 9)
            bindOptionalText(page.languageCode, to: statement, index: 10)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }

        for content in pageContents {
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    db,
                    "INSERT INTO MyDocumentPageContent (pageId, content) VALUES (?, ?)",
                    -1,
                    &statement,
                    nil
                ),
                SQLITE_OK
            )
            bindUUIDBlob(content.pageId, to: statement, index: 1)
            sqlite3_bind_text(statement, 2, content.content, -1, myDocumentRestoreSQLiteTransient)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }

        for cacheEntry in aiPageCacheEntries {
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    db,
                    "INSERT INTO AiPageCacheEntry (pageId, sourcePromptId, sourceContext, kjvOrdinalStart, kjvOrdinalEnd, contextHash, usedWriteTools, sourceModelName, sourceBookInitials, sourceBookKey) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    -1,
                    &statement,
                    nil
                ),
                SQLITE_OK
            )
            bindUUIDBlob(cacheEntry.pageId, to: statement, index: 1)
            bindUUIDBlob(cacheEntry.sourcePromptId, to: statement, index: 2)
            bindOptionalText(cacheEntry.sourceContext, to: statement, index: 3)
            bindOptionalInt(cacheEntry.kjvOrdinalStart, to: statement, index: 4)
            bindOptionalInt(cacheEntry.kjvOrdinalEnd, to: statement, index: 5)
            bindOptionalText(cacheEntry.contextHash, to: statement, index: 6)
            sqlite3_bind_int(statement, 7, cacheEntry.usedWriteTools ? 1 : 0)
            bindOptionalText(cacheEntry.sourceModelName, to: statement, index: 8)
            bindOptionalText(cacheEntry.sourceBookInitials, to: statement, index: 9)
            bindOptionalText(cacheEntry.sourceBookKey, to: statement, index: 10)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }

        for logEntry in logEntries {
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    db,
                    "INSERT INTO LogEntry (tableName, entityId1, entityId2, type, lastUpdated, sourceDevice) VALUES (?, ?, ?, ?, ?, ?)",
                    -1,
                    &statement,
                    nil
                ),
                SQLITE_OK
            )
            sqlite3_bind_text(statement, 1, logEntry.tableName, -1, myDocumentRestoreSQLiteTransient)
            bindSQLiteValue(logEntry.entityID1, to: statement, index: 2)
            bindSQLiteValue(logEntry.entityID2, to: statement, index: 3)
            sqlite3_bind_text(statement, 4, logEntry.type.rawValue, -1, myDocumentRestoreSQLiteTransient)
            sqlite3_bind_int64(statement, 5, logEntry.lastUpdated)
            sqlite3_bind_text(statement, 6, logEntry.sourceDevice, -1, myDocumentRestoreSQLiteTransient)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }

        for syncStatus in syncStatuses {
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    db,
                    "INSERT INTO SyncStatus (sourceDevice, patchNumber, sizeBytes, appliedDate) VALUES (?, ?, ?, ?)",
                    -1,
                    &statement,
                    nil
                ),
                SQLITE_OK
            )
            sqlite3_bind_text(statement, 1, syncStatus.sourceDevice, -1, myDocumentRestoreSQLiteTransient)
            sqlite3_bind_int64(statement, 2, syncStatus.patchNumber)
            sqlite3_bind_int64(statement, 3, syncStatus.sizeBytes)
            sqlite3_bind_int64(statement, 4, syncStatus.appliedDate)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }

        return databaseURL
    }

    private struct AndroidMyDocumentRow {
        let id: UUID
        let name: String
        var documentDescription: String? = nil
        let initials: String
        var orderNumber: Int = 0
        var createdAt: Date = Date(timeIntervalSince1970: 1_735_689_600)
        var updatedAt: Date = Date(timeIntervalSince1970: 1_735_689_600)
        var sourcePromptId: UUID? = nil
    }

    private struct AndroidMyDocumentPageRow {
        let id: UUID
        let documentId: UUID
        let title: String
        let pageKey: String
        var contentType: MyDocumentContentType = .markdown
        var contentTypeRawValue: String? = nil
        var orderNumber: Int = 0
        var createdAt: Date = Date(timeIntervalSince1970: 1_735_689_600)
        var updatedAt: Date = Date(timeIntervalSince1970: 1_735_689_600)
        var sourcePromptId: UUID? = nil
        var languageCode: String? = nil
    }

    private struct AndroidMyDocumentPageContentRow {
        let pageId: UUID
        let content: String
    }

    private struct AndroidAiPageCacheEntryRow {
        let pageId: UUID
        let sourcePromptId: UUID
        var sourceContext: String? = nil
        var kjvOrdinalStart: Int? = nil
        var kjvOrdinalEnd: Int? = nil
        var contextHash: String? = nil
        var usedWriteTools: Bool = false
        var sourceModelName: String? = nil
        var sourceBookInitials: String? = nil
        var sourceBookKey: String? = nil
    }

    private func bindUUIDBlob(_ value: UUID, to statement: OpaquePointer?, index: Int32) {
        let blob = uuidBlob(value)
        _ = blob.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(blob.count), myDocumentRestoreSQLiteTransient)
        }
    }

    private func bindOptionalUUIDBlob(_ value: UUID?, to statement: OpaquePointer?, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        bindUUIDBlob(value, to: statement, index: index)
    }

    private func bindSQLiteValue(_ value: RemoteSyncSQLiteValue, to statement: OpaquePointer?, index: Int32) {
        switch value.kind {
        case .null:
            sqlite3_bind_null(statement, index)
        case .integer:
            sqlite3_bind_int64(statement, index, value.integerValue ?? 0)
        case .real:
            sqlite3_bind_double(statement, index, value.realValue ?? 0)
        case .text:
            sqlite3_bind_text(statement, index, value.textValue ?? "", -1, myDocumentRestoreSQLiteTransient)
        case .blob:
            let data = value.blobData ?? Data()
            _ = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(data.count), myDocumentRestoreSQLiteTransient)
            }
        }
    }

    private func bindDate(_ value: Date, to statement: OpaquePointer?, index: Int32) {
        sqlite3_bind_int64(statement, index, Int64(value.timeIntervalSince1970 * 1000.0))
    }

    private func bindOptionalText(_ value: String?, to statement: OpaquePointer?, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, myDocumentRestoreSQLiteTransient)
    }

    private func bindOptionalInt(_ value: Int?, to statement: OpaquePointer?, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int(statement, index, Int32(value))
    }

    private func myDocumentLogEntry(
        tableName: String,
        rowID: UUID,
        type: RemoteSyncLogEntryType,
        timestamp: Int64 = 2_000,
        sourceDevice: String = "pixel"
    ) -> RemoteSyncLogEntry {
        RemoteSyncLogEntry(
            tableName: tableName,
            entityID1: .blob(uuidBlob(rowID)),
            entityID2: .text(""),
            type: type,
            lastUpdated: timestamp,
            sourceDevice: sourceDevice
        )
    }

    private func myDocumentLogEntries(
        documentIDs: [UUID],
        pageIDs: [UUID],
        timestamp: Int64,
        sourceDevice: String
    ) -> [RemoteSyncLogEntry] {
        documentIDs.map {
            RemoteSyncLogEntry(
                tableName: "MyDocument",
                entityID1: .blob(uuidBlob($0)),
                entityID2: .text(""),
                type: .upsert,
                lastUpdated: timestamp,
                sourceDevice: sourceDevice
            )
        } + pageIDs.flatMap {
            [
                RemoteSyncLogEntry(
                    tableName: "MyDocumentPage",
                    entityID1: .blob(uuidBlob($0)),
                    entityID2: .text(""),
                    type: .upsert,
                    lastUpdated: timestamp,
                    sourceDevice: sourceDevice
                ),
                RemoteSyncLogEntry(
                    tableName: "MyDocumentPageContent",
                    entityID1: .blob(uuidBlob($0)),
                    entityID2: .text(""),
                    type: .upsert,
                    lastUpdated: timestamp,
                    sourceDevice: sourceDevice
                ),
                RemoteSyncLogEntry(
                    tableName: "AiPageCacheEntry",
                    entityID1: .blob(uuidBlob($0)),
                    entityID2: .text(""),
                    type: .upsert,
                    lastUpdated: timestamp,
                    sourceDevice: sourceDevice
                ),
            ]
        }
    }

    private func uuidBlob(_ value: UUID) -> Data {
        var uuid = value.uuid
        return withUnsafeBytes(of: &uuid) { Data($0) }
    }
}

private actor MyDocumentMockRemoteSyncAdapter: RemoteSyncAdapting {
    private var uploadResults: [RemoteSyncFile] = []
    private var knownResponses: [String: Bool] = [:]
    private var listedFilesByParentID: [String: [RemoteSyncFile]] = [:]
    private var downloadDataByID: [String: Data] = [:]
    private var uploadedFiles: [MyDocumentMockUploadedFile] = []

    func enqueueUploadResult(_ result: RemoteSyncFile) {
        uploadResults.append(result)
    }

    func setKnownResponse(_ value: Bool, forSyncFolderID syncFolderID: String, secretFileName: String) {
        knownResponses["\(syncFolderID)|\(secretFileName)"] = value
    }

    func setListedFiles(_ files: [RemoteSyncFile], forParentID parentID: String) {
        listedFilesByParentID[parentID] = files
    }

    func setDownloadData(_ data: Data, forID id: String) {
        downloadDataByID[id] = data
    }

    func uploadedFilesSnapshot() -> [MyDocumentMockUploadedFile] {
        uploadedFiles
    }

    func listFiles(
        parentIDs: [String]?,
        name: String?,
        mimeType: String?,
        modifiedAtLeast: Date?
    ) async throws -> [RemoteSyncFile] {
        let files: [RemoteSyncFile]
        if let parentIDs {
            files = parentIDs.flatMap { listedFilesByParentID[$0, default: []] }
        } else {
            files = listedFilesByParentID.values.flatMap { $0 }
        }

        return files.filter { file in
            if let name, file.name != name {
                return false
            }
            if let mimeType, file.mimeType != mimeType {
                return false
            }
            if let modifiedAtLeast {
                let modifiedDate = Date(timeIntervalSince1970: TimeInterval(file.timestamp) / 1000.0)
                if modifiedDate < modifiedAtLeast {
                    return false
                }
            }
            return true
        }
    }

    func createNewFolder(name: String, parentID: String?) async throws -> RemoteSyncFile {
        RemoteSyncFile(
            id: [parentID, name].compactMap { $0 }.joined(separator: "/"),
            name: name,
            size: 0,
            timestamp: 0,
            parentID: parentID ?? "/",
            mimeType: NextCloudSyncAdapter.folderMimeType
        )
    }

    func download(id: String) async throws -> Data {
        downloadDataByID[id] ?? Data()
    }

    func upload(
        name: String,
        fileURL: URL,
        parentID: String,
        contentType: String
    ) async throws -> RemoteSyncFile {
        let data = try Data(contentsOf: fileURL)
        uploadedFiles.append(
            MyDocumentMockUploadedFile(
                name: name,
                parentID: parentID,
                contentType: contentType,
                data: data
            )
        )
        if !uploadResults.isEmpty {
            let result = uploadResults.removeFirst()
            return RemoteSyncFile(
                id: result.id,
                name: result.name,
                size: Int64(data.count),
                timestamp: result.timestamp,
                parentID: result.parentID,
                mimeType: result.mimeType
            )
        }
        return RemoteSyncFile(
            id: [parentID, name].joined(separator: "/"),
            name: name,
            size: Int64(data.count),
            timestamp: 0,
            parentID: parentID,
            mimeType: contentType
        )
    }

    func delete(id: String) async throws {}

    func isSyncFolderKnown(syncFolderID: String, secretFileName: String) async throws -> Bool {
        knownResponses["\(syncFolderID)|\(secretFileName)"] ?? false
    }

    func makeSyncFolderKnown(syncFolderID: String, deviceIdentifier: String) async throws -> String {
        "device-known-\(deviceIdentifier)-secret"
    }
}

private struct MyDocumentMockUploadedFile: Equatable {
    let name: String
    let parentID: String
    let contentType: String
    let data: Data
}

private func writeUploadedMyDocumentDatabase(_ archiveData: Data) throws -> URL {
    let databaseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("uploaded-mydocuments-\(UUID().uuidString).sqlite3")
    let databaseData = try myDocumentGunzipTestData(archiveData)
    try databaseData.write(to: databaseURL, options: .atomic)
    return databaseURL
}

private func myDocumentGunzipTestData(_ data: Data) throws -> Data {
    try data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Data in
        guard let baseAddress = ptr.baseAddress else {
            throw RemoteSyncArchiveStagingError.decompressionFailed
        }

        var outputLength: UInt = 0
        guard let output = gunzip_data(
            baseAddress.assumingMemoryBound(to: UInt8.self),
            UInt(data.count),
            &outputLength
        ) else {
            throw RemoteSyncArchiveStagingError.decompressionFailed
        }

        defer { gunzip_free(output) }
        return Data(bytes: output, count: Int(outputLength))
    }
}

private func sqliteUserVersion(at databaseURL: URL) throws -> Int {
    var db: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
        throw RemoteSyncMyDocumentRestoreError.invalidSQLiteDatabase
    }
    defer { sqlite3_close(db) }

    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK,
          sqlite3_step(statement) == SQLITE_ROW else {
        throw RemoteSyncMyDocumentRestoreError.invalidSQLiteDatabase
    }
    return Int(sqlite3_column_int(statement, 0))
}

private func sqliteRoomIdentityHash(at databaseURL: URL) throws -> String {
    var db: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
        throw RemoteSyncMyDocumentRestoreError.invalidSQLiteDatabase
    }
    defer { sqlite3_close(db) }

    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    guard sqlite3_prepare_v2(db, "SELECT identity_hash FROM room_master_table WHERE id = 42;", -1, &statement, nil) == SQLITE_OK,
          sqlite3_step(statement) == SQLITE_ROW,
          let value = sqlite3_column_text(statement, 0) else {
        throw RemoteSyncMyDocumentRestoreError.invalidSQLiteDatabase
    }
    return String(cString: value)
}

private func sqliteColumnDefault(tableName: String, columnName: String, databaseURL: URL) throws -> String? {
    var db: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
        throw RemoteSyncMyDocumentRestoreError.invalidSQLiteDatabase
    }
    defer { sqlite3_close(db) }

    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(tableName));", -1, &statement, nil) == SQLITE_OK else {
        throw RemoteSyncMyDocumentRestoreError.invalidSQLiteDatabase
    }

    while sqlite3_step(statement) == SQLITE_ROW {
        guard let rawName = sqlite3_column_text(statement, 1) else {
            continue
        }
        guard String(cString: rawName) == columnName else {
            continue
        }
        guard sqlite3_column_type(statement, 4) != SQLITE_NULL,
              let defaultValue = sqlite3_column_text(statement, 4) else {
            return nil
        }
        return String(cString: defaultValue)
    }
    throw RemoteSyncMyDocumentRestoreError.invalidSQLiteDatabase
}

private func sqliteCount(tableName: String, databaseURL: URL) throws -> Int {
    var db: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
        throw RemoteSyncMyDocumentRestoreError.invalidSQLiteDatabase
    }
    defer { sqlite3_close(db) }

    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(tableName)", -1, &statement, nil) == SQLITE_OK,
          sqlite3_step(statement) == SQLITE_ROW else {
        throw RemoteSyncMyDocumentRestoreError.invalidSQLiteDatabase
    }
    return Int(sqlite3_column_int(statement, 0))
}
