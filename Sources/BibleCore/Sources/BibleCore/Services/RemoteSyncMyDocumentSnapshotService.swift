// RemoteSyncMyDocumentSnapshotService.swift -- Android-shaped local My Documents snapshots for outbound sync

import CryptoKit
import Foundation
import SwiftData

/**
 Snapshot of current local My Documents state expressed in Android row form.

 The snapshot carries row maps keyed by Android's `(tableName, entityId1, entityId2)` sync identity
 plus stable content fingerprints so later patch upload work can diff against the accepted
 baseline without re-reading SwiftData.
 */
public struct RemoteSyncMyDocumentCurrentSnapshot: Sendable, Equatable {
    /// Android-shaped current `MyDocument` rows keyed by Android composite key.
    public let documentRowsByKey: [String: RemoteSyncAndroidMyDocument]

    /// Android-shaped current `MyDocumentPage` rows keyed by Android composite key.
    public let pageRowsByKey: [String: RemoteSyncAndroidMyDocumentPage]

    /// Android-shaped current `MyDocumentPageContent` rows keyed by Android composite key.
    public let pageContentRowsByKey: [String: RemoteSyncAndroidMyDocumentPageContent]

    /// Android-shaped current `AiPageCacheEntry` rows keyed by Android composite key.
    public let aiPageCacheEntryRowsByKey: [String: RemoteSyncAndroidAiPageCacheEntry]

    /// Stable content fingerprints for every current row keyed by Android composite key.
    public let fingerprintsByKey: [String: String]

    public init(
        documentRowsByKey: [String: RemoteSyncAndroidMyDocument],
        pageRowsByKey: [String: RemoteSyncAndroidMyDocumentPage],
        pageContentRowsByKey: [String: RemoteSyncAndroidMyDocumentPageContent],
        aiPageCacheEntryRowsByKey: [String: RemoteSyncAndroidAiPageCacheEntry],
        fingerprintsByKey: [String: String]
    ) {
        self.documentRowsByKey = documentRowsByKey
        self.pageRowsByKey = pageRowsByKey
        self.pageContentRowsByKey = pageContentRowsByKey
        self.aiPageCacheEntryRowsByKey = aiPageCacheEntryRowsByKey
        self.fingerprintsByKey = fingerprintsByKey
    }
}

/**
 Projects local My Documents SwiftData rows into Android My Documents sync rows.

 Android defines My Documents as four sync targets in `SyncUtilities.kt`:
 `MyDocument`, `MyDocumentPage`, `MyDocumentPageContent`, and `AiPageCacheEntry`. This service
 mirrors those table identities and uses `pageId` for the detached content/cache targets so iOS
 initial backups and future patches match Android's trigger contract.

 Side effects:
 - `snapshotCurrentState` reads `MyDocument`, `MyDocumentPage`, `MyDocumentPageContent`, and
   `AiPageCacheEntry` rows from SwiftData
 - `refreshBaselineFingerprints` rewrites the local fingerprint baseline for the My Documents
   category

 Failure modes:
 - fetch failures from `ModelContext` are swallowed and treated as an empty snapshot, matching the
   existing outbound snapshot services
 */
public final class RemoteSyncMyDocumentSnapshotService {
    public init() {}

    /**
     Projects the current local My Documents graph into Android-shaped rows.
     */
    public func snapshotCurrentState(
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) -> RemoteSyncMyDocumentCurrentSnapshot {
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let documents = ((try? modelContext.fetch(FetchDescriptor<MyDocument>())) ?? [])
            .sorted(by: Self.documentSort)
        let pages = ((try? modelContext.fetch(FetchDescriptor<MyDocumentPage>())) ?? [])
            .sorted(by: Self.pageSort)
        let pageContents = ((try? modelContext.fetch(FetchDescriptor<MyDocumentPageContent>())) ?? [])
            .sorted { $0.pageId.uuidString < $1.pageId.uuidString }
        let aiPageCacheEntries = ((try? modelContext.fetch(FetchDescriptor<AiPageCacheEntry>())) ?? [])
            .sorted(by: Self.aiPageCacheEntrySort)

        let documentIDs = Set(documents.map(\.id))
        var pageIDs: Set<UUID> = []
        var emittedAIPageCachePageIDs: Set<UUID> = []
        var documentRowsByKey: [String: RemoteSyncAndroidMyDocument] = [:]
        var pageRowsByKey: [String: RemoteSyncAndroidMyDocumentPage] = [:]
        var pageContentRowsByKey: [String: RemoteSyncAndroidMyDocumentPageContent] = [:]
        var aiPageCacheEntryRowsByKey: [String: RemoteSyncAndroidAiPageCacheEntry] = [:]
        var fingerprintsByKey: [String: String] = [:]

        for document in documents {
            let row = RemoteSyncAndroidMyDocument(
                id: document.id,
                name: document.name,
                documentDescription: document.documentDescription,
                initials: document.initials,
                orderNumber: document.orderNumber,
                createdAt: document.createdAt,
                updatedAt: document.updatedAt,
                sourcePromptId: document.sourcePromptId
            )
            let key = logEntryStore.key(
                for: .myDocuments,
                tableName: "MyDocument",
                entityID1: .blob(Self.uuidBlob(row.id)),
                entityID2: .text("")
            )
            documentRowsByKey[key] = row
            fingerprintsByKey[key] = Self.fingerprintHex(for: row)
        }

        for page in pages {
            guard let documentID = page.document?.id, documentIDs.contains(documentID) else {
                continue
            }
            let row = RemoteSyncAndroidMyDocumentPage(
                id: page.id,
                documentId: documentID,
                title: page.title,
                pageKey: page.pageKey,
                contentType: page.contentType,
                orderNumber: page.orderNumber,
                createdAt: page.createdAt,
                updatedAt: page.updatedAt,
                sourcePromptId: page.sourcePromptId,
                languageCode: page.languageCode
            )
            let key = logEntryStore.key(
                for: .myDocuments,
                tableName: "MyDocumentPage",
                entityID1: .blob(Self.uuidBlob(row.id)),
                entityID2: .text("")
            )
            pageIDs.insert(row.id)
            pageRowsByKey[key] = row
            fingerprintsByKey[key] = Self.fingerprintHex(for: row)
        }

        for pageContent in pageContents where pageIDs.contains(pageContent.pageId) {
            let row = RemoteSyncAndroidMyDocumentPageContent(
                pageId: pageContent.pageId,
                content: pageContent.content
            )
            let key = logEntryStore.key(
                for: .myDocuments,
                tableName: "MyDocumentPageContent",
                entityID1: .blob(Self.uuidBlob(row.pageId)),
                entityID2: .text("")
            )
            pageContentRowsByKey[key] = row
            fingerprintsByKey[key] = Self.fingerprintHex(for: row)
        }

        for cacheEntry in aiPageCacheEntries where pageIDs.contains(cacheEntry.pageId) {
            guard emittedAIPageCachePageIDs.insert(cacheEntry.pageId).inserted else {
                continue
            }
            let row = RemoteSyncAndroidAiPageCacheEntry(
                pageId: cacheEntry.pageId,
                sourcePromptId: cacheEntry.sourcePromptId,
                sourceContext: cacheEntry.sourceContext,
                kjvOrdinalStart: cacheEntry.kjvOrdinalStart,
                kjvOrdinalEnd: cacheEntry.kjvOrdinalEnd,
                contextHash: cacheEntry.contextHash,
                usedWriteTools: cacheEntry.usedWriteTools,
                sourceModelName: cacheEntry.sourceModelName,
                sourceBookInitials: cacheEntry.sourceBookInitials,
                sourceBookKey: cacheEntry.sourceBookKey
            )
            let key = logEntryStore.key(
                for: .myDocuments,
                tableName: "AiPageCacheEntry",
                entityID1: .blob(Self.uuidBlob(row.pageId)),
                entityID2: .text("")
            )
            aiPageCacheEntryRowsByKey[key] = row
            fingerprintsByKey[key] = Self.fingerprintHex(for: row)
        }

        return RemoteSyncMyDocumentCurrentSnapshot(
            documentRowsByKey: documentRowsByKey,
            pageRowsByKey: pageRowsByKey,
            pageContentRowsByKey: pageContentRowsByKey,
            aiPageCacheEntryRowsByKey: aiPageCacheEntryRowsByKey,
            fingerprintsByKey: fingerprintsByKey
        )
    }

    /**
     Replaces the stored fingerprint baseline with the current My Documents snapshot.
     */
    public func refreshBaselineFingerprints(
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) {
        let snapshot = snapshotCurrentState(modelContext: modelContext, settingsStore: settingsStore)
        let fingerprintStore = RemoteSyncRowFingerprintStore(settingsStore: settingsStore)
        fingerprintStore.clearCategory(.myDocuments)

        for (key, row) in snapshot.documentRowsByKey {
            guard let fingerprint = snapshot.fingerprintsByKey[key] else {
                continue
            }
            fingerprintStore.setFingerprint(
                fingerprint,
                for: .myDocuments,
                tableName: "MyDocument",
                entityID1: .blob(Self.uuidBlob(row.id)),
                entityID2: .text("")
            )
        }

        for (key, row) in snapshot.pageRowsByKey {
            guard let fingerprint = snapshot.fingerprintsByKey[key] else {
                continue
            }
            fingerprintStore.setFingerprint(
                fingerprint,
                for: .myDocuments,
                tableName: "MyDocumentPage",
                entityID1: .blob(Self.uuidBlob(row.id)),
                entityID2: .text("")
            )
        }

        for (key, row) in snapshot.pageContentRowsByKey {
            guard let fingerprint = snapshot.fingerprintsByKey[key] else {
                continue
            }
            fingerprintStore.setFingerprint(
                fingerprint,
                for: .myDocuments,
                tableName: "MyDocumentPageContent",
                entityID1: .blob(Self.uuidBlob(row.pageId)),
                entityID2: .text("")
            )
        }

        for (key, row) in snapshot.aiPageCacheEntryRowsByKey {
            guard let fingerprint = snapshot.fingerprintsByKey[key] else {
                continue
            }
            fingerprintStore.setFingerprint(
                fingerprint,
                for: .myDocuments,
                tableName: "AiPageCacheEntry",
                entityID1: .blob(Self.uuidBlob(row.pageId)),
                entityID2: .text("")
            )
        }
    }

    /**
     Converts one UUID into Android's raw 16-byte blob representation.
     */
    public static func uuidBlob(_ uuid: UUID) -> Data {
        withUnsafeBytes(of: uuid.uuid) { Data($0) }
    }

    static func fingerprintHex(for value: RemoteSyncAndroidMyDocument) -> String {
        fingerprintHex(
            canonicalValue: [
                value.id.uuidString.lowercased(),
                value.name,
                value.documentDescription ?? "",
                value.initials,
                String(value.orderNumber),
                canonicalDateMillis(value.createdAt),
                canonicalDateMillis(value.updatedAt),
                value.sourcePromptId?.uuidString.lowercased() ?? "",
            ].joined(separator: "|")
        )
    }

    static func fingerprintHex(for value: RemoteSyncAndroidMyDocumentPage) -> String {
        fingerprintHex(
            canonicalValue: [
                value.id.uuidString.lowercased(),
                value.documentId.uuidString.lowercased(),
                value.title,
                value.pageKey,
                value.contentType.rawValue,
                String(value.orderNumber),
                canonicalDateMillis(value.createdAt),
                canonicalDateMillis(value.updatedAt),
                value.sourcePromptId?.uuidString.lowercased() ?? "",
                value.languageCode ?? "",
            ].joined(separator: "|")
        )
    }

    static func fingerprintHex(for value: RemoteSyncAndroidMyDocumentPageContent) -> String {
        fingerprintHex(
            canonicalValue: [
                value.pageId.uuidString.lowercased(),
                value.content,
            ].joined(separator: "|")
        )
    }

    static func fingerprintHex(for value: RemoteSyncAndroidAiPageCacheEntry) -> String {
        fingerprintHex(
            canonicalValue: [
                value.pageId.uuidString.lowercased(),
                value.sourcePromptId.uuidString.lowercased(),
                value.sourceContext ?? "",
                canonicalOptionalInt(value.kjvOrdinalStart),
                canonicalOptionalInt(value.kjvOrdinalEnd),
                value.contextHash ?? "",
                canonicalBool(value.usedWriteTools),
                value.sourceModelName ?? "",
                value.sourceBookInitials ?? "",
                value.sourceBookKey ?? "",
            ].joined(separator: "|")
        )
    }

    private static func documentSort(_ lhs: MyDocument, _ rhs: MyDocument) -> Bool {
        if lhs.orderNumber == rhs.orderNumber {
            if lhs.name == rhs.name {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.name < rhs.name
        }
        return lhs.orderNumber < rhs.orderNumber
    }

    private static func pageSort(_ lhs: MyDocumentPage, _ rhs: MyDocumentPage) -> Bool {
        let lhsDocumentID = lhs.document?.id.uuidString ?? ""
        let rhsDocumentID = rhs.document?.id.uuidString ?? ""
        if lhsDocumentID == rhsDocumentID {
            if lhs.orderNumber == rhs.orderNumber {
                if lhs.title == rhs.title {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.title < rhs.title
            }
            return lhs.orderNumber < rhs.orderNumber
        }
        return lhsDocumentID < rhsDocumentID
    }

    private static func aiPageCacheEntrySort(_ lhs: AiPageCacheEntry, _ rhs: AiPageCacheEntry) -> Bool {
        if lhs.pageId == rhs.pageId {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.pageId.uuidString < rhs.pageId.uuidString
    }

    private static func canonicalDateMillis(_ value: Date) -> String {
        String(Int64(value.timeIntervalSince1970 * 1000.0))
    }

    private static func canonicalOptionalInt(_ value: Int?) -> String {
        value.map(String.init) ?? ""
    }

    private static func canonicalBool(_ value: Bool) -> String {
        value ? "1" : "0"
    }

    private static func fingerprintHex(canonicalValue: String) -> String {
        let digest = SHA256.hash(data: Data(canonicalValue.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
