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
 Durable Android identity for one accepted My Documents row.

 The identity manifest complements fingerprints so a deletion remains discoverable even when an
 accepted initial backup had no current `LogEntry` rows.
 */
struct RemoteSyncMyDocumentAcceptedRowIdentity: Codable, Sendable, Equatable {
    /// Canonical My Documents log key.
    let key: String

    /// Android table that owns the row.
    let tableName: String

    /// First Android composite-key component.
    let entityID1: RemoteSyncSQLiteValue

    /// Second Android composite-key component.
    let entityID2: RemoteSyncSQLiteValue
}

/**
 Immutable My Documents fingerprint and accepted-key generation.
 */
struct RemoteSyncMyDocumentAcceptedBaseline: Codable, Sendable, Equatable {
    /// Opaque publication revision used to reject stale outbox acceptance.
    let revision: UUID?

    /// Exact projected fingerprints keyed by canonical Android log key.
    let fingerprintsByKey: [String: String]

    /// Accepted Android row identities used to emit later deletes.
    let rowIdentities: [RemoteSyncMyDocumentAcceptedRowIdentity]

    /** Creates one immutable accepted My Documents generation. */
    init(
        revision: UUID? = UUID(),
        fingerprintsByKey: [String: String],
        rowIdentities: [RemoteSyncMyDocumentAcceptedRowIdentity]
    ) {
        self.revision = revision
        self.fingerprintsByKey = fingerprintsByKey
        self.rowIdentities = rowIdentities
    }
}

/**
 Errors raised while reading or publishing the durable My Documents accepted baseline.
 */
enum RemoteSyncMyDocumentAcceptedBaselineError: Error, Equatable {
    /// Persisted JSON could not be decoded as a complete accepted generation.
    case invalidStoredBaseline

    /// A projected fingerprint key did not belong to the My Documents namespace.
    case invalidFingerprintKey(String)

    /// An exportable projected row had no stable fingerprint.
    case missingProjectedFingerprint(String)

    /// The accepted baseline changed after an outbox generation was projected.
    case staleAcceptedBaseline
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
 - compatibility projection methods swallow per-table fetch failures for existing outbound callers
 - throwing projection and baseline methods propagate the first fetch failure before publication
 */
public final class RemoteSyncMyDocumentSnapshotService {
    /// Single settings key containing the accepted My Documents row-identity manifest.
    static let acceptedBaselineKey = "remote_sync.accepted_baseline.mydocuments"

    // Android sync triggers write the SQL literal '' for entityId2 on single-key tables.
    static let emptySecondaryEntityID = RemoteSyncSQLiteValue.text("")

    /// Deterministic pre-fetch checkpoint used by tests to model a strict SwiftData read failure.
    private let strictSnapshotCheckpoint: () throws -> Void

    /**
     Creates a My Documents snapshot service with production strict-read behavior.

     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init() {
        strictSnapshotCheckpoint = {}
    }

    /**
     Creates a snapshot service with a deterministic strict-read checkpoint for data-safety tests.

     - Parameter strictSnapshotCheckpoint: Callback invoked before every throwing graph projection.
     - Side effects: Stores the callback without invoking it.
     - Failure modes: This initializer cannot fail; callback errors are rethrown by strict methods.
     */
    init(strictSnapshotCheckpoint: @escaping () throws -> Void) {
        self.strictSnapshotCheckpoint = strictSnapshotCheckpoint
    }

    /**
     Projects the current local My Documents graph into Android-shaped rows.
     */
    public func snapshotCurrentState(
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) -> RemoteSyncMyDocumentCurrentSnapshot {
        let documents = ((try? modelContext.fetch(FetchDescriptor<MyDocument>())) ?? [])
            .sorted(by: Self.documentSort)
        let pages = ((try? modelContext.fetch(FetchDescriptor<MyDocumentPage>())) ?? [])
            .sorted(by: Self.pageSort)
        let pageContents = ((try? modelContext.fetch(FetchDescriptor<MyDocumentPageContent>())) ?? [])
            .sorted { $0.pageId.uuidString < $1.pageId.uuidString }
        let aiPageCacheEntries = ((try? modelContext.fetch(FetchDescriptor<AiPageCacheEntry>())) ?? [])
            .sorted(by: Self.aiPageCacheEntrySort)

        return buildSnapshot(
            documents: documents,
            pages: pages,
            pageContents: pageContents,
            aiPageCacheEntries: aiPageCacheEntries,
            settingsStore: settingsStore
        )
    }

    /**
     Projects the current local My Documents graph into Android-shaped rows while preserving fetch failures.

     Patch replay uses this throwing variant because treating a failed local fetch as an empty graph
     could make an accepted remote patch replace local My Documents with only sparse patch rows.

     - Parameters:
       - modelContext: SwiftData context that owns the local My Documents graph.
       - settingsStore: Local settings store used to build Android-compatible log keys.
     - Returns: Android-shaped current-state snapshot for replay.
     - Side effects: reads My Documents SwiftData rows.
     - Failure modes: Rethrows SwiftData fetch failures from `ModelContext`.
     */
    public func snapshotCurrentStateThrowing(
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws -> RemoteSyncMyDocumentCurrentSnapshot {
        try strictSnapshotCheckpoint()
        let documents = try modelContext.fetch(FetchDescriptor<MyDocument>())
            .sorted(by: Self.documentSort)
        let pages = try modelContext.fetch(FetchDescriptor<MyDocumentPage>())
            .sorted(by: Self.pageSort)
        let pageContents = try modelContext.fetch(FetchDescriptor<MyDocumentPageContent>())
            .sorted { $0.pageId.uuidString < $1.pageId.uuidString }
        let aiPageCacheEntries = try modelContext.fetch(FetchDescriptor<AiPageCacheEntry>())
            .sorted(by: Self.aiPageCacheEntrySort)

        return buildSnapshot(
            documents: documents,
            pages: pages,
            pageContents: pageContents,
            aiPageCacheEntries: aiPageCacheEntries,
            settingsStore: settingsStore
        )
    }

    /**
     Builds the Android-shaped snapshot maps from already fetched and sorted SwiftData rows.

     - Parameters:
       - documents: Local document rows sorted for deterministic output.
       - pages: Local page rows sorted for deterministic output.
       - pageContents: Local content rows sorted for deterministic output.
       - aiPageCacheEntries: Local AI-cache rows sorted for deterministic output.
       - settingsStore: Local settings store used to derive Android sync keys.
     - Returns: Current-state snapshot with Android-shaped rows and fingerprints.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func buildSnapshot(
        documents: [MyDocument],
        pages: [MyDocumentPage],
        pageContents: [MyDocumentPageContent],
        aiPageCacheEntries: [AiPageCacheEntry],
        settingsStore: SettingsStore
    ) -> RemoteSyncMyDocumentCurrentSnapshot {
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
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
                entityID2: Self.emptySecondaryEntityID
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
                entityID2: Self.emptySecondaryEntityID
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
                entityID2: Self.emptySecondaryEntityID
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
                entityID2: Self.emptySecondaryEntityID
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
     Compatibility wrapper that replaces My Documents fingerprints from a fail-soft snapshot.

     Existing non-destructive callers retain this API shape. Atomic publication must use
     `refreshBaselineFingerprintsThrowing` so graph fetch failures abort before baseline mutation.

     - Parameters:
       - modelContext: SwiftData context that owns the current My Documents graph.
       - settingsStore: Settings store receiving the compatibility baseline.
     - Side effects: Replaces My Documents fingerprints from the compatibility projection.
     - Failure modes: SwiftData fetch failures are swallowed by `snapshotCurrentState` and projected
       as empty tables, preserving the historical outbound-call contract.
     */
    public func refreshBaselineFingerprints(
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) {
        let snapshot = snapshotCurrentState(modelContext: modelContext, settingsStore: settingsStore)
        try? acceptBaseline(acceptedBaseline(from: snapshot), settingsStore: settingsStore)
    }

    /**
     Replaces My Documents fingerprints only after a complete strict graph projection succeeds.

     Atomic restore and patch publication use this path so a failed graph read cannot clear the
     accepted baseline or publish fingerprints for an authoritative empty snapshot.

     - Parameters:
       - modelContext: SwiftData context that owns the current My Documents graph.
       - settingsStore: Settings store receiving the fingerprint baseline.
     - Side effects: Replaces My Documents fingerprints after every graph table has been read.
     - Failure modes: Rethrows the strict checkpoint and any SwiftData fetch failure before baseline
       mutation begins.
     */
    public func refreshBaselineFingerprintsThrowing(
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws {
        let snapshot = try snapshotCurrentStateThrowing(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        try acceptBaseline(acceptedBaselineThrowing(from: snapshot), settingsStore: settingsStore)
    }

    /**
     Converts one complete My Documents projection into an immutable accepted generation.

     - Parameter snapshot: Successfully projected My Documents rows and fingerprints.
     - Returns: Exact fingerprints and accepted Android row identities for the projection.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    func acceptedBaseline(
        from snapshot: RemoteSyncMyDocumentCurrentSnapshot
    ) -> RemoteSyncMyDocumentAcceptedBaseline {
        RemoteSyncMyDocumentAcceptedBaseline(
            fingerprintsByKey: snapshot.fingerprintsByKey,
            rowIdentities: acceptedRowIdentities(from: snapshot)
        )
    }

    /**
     Converts a strict My Documents projection into a validated accepted generation.

     - Parameter snapshot: Complete strict projection.
     - Returns: Immutable fingerprints and row identities for the projected generation.
     - Side effects: none.
     - Failure modes: Throws `missingProjectedFingerprint` when any exportable row lacks a stable
       fingerprint.
     */
    func acceptedBaselineThrowing(
        from snapshot: RemoteSyncMyDocumentCurrentSnapshot
    ) throws -> RemoteSyncMyDocumentAcceptedBaseline {
        let identities = acceptedRowIdentities(from: snapshot)
        for identity in identities where snapshot.fingerprintsByKey[identity.key] == nil {
            throw RemoteSyncMyDocumentAcceptedBaselineError.missingProjectedFingerprint(identity.key)
        }
        return RemoteSyncMyDocumentAcceptedBaseline(
            fingerprintsByKey: snapshot.fingerprintsByKey,
            rowIdentities: identities
        )
    }

    /** Collects deterministic Android row identities for one My Documents projection. */
    private func acceptedRowIdentities(
        from snapshot: RemoteSyncMyDocumentCurrentSnapshot
    ) -> [RemoteSyncMyDocumentAcceptedRowIdentity] {
        var identities: [RemoteSyncMyDocumentAcceptedRowIdentity] = []

        /** Appends one Android row identity to the immutable baseline. */
        func append(key: String, tableName: String, rowID: UUID) {
            identities.append(
                RemoteSyncMyDocumentAcceptedRowIdentity(
                    key: key,
                    tableName: tableName,
                    entityID1: .blob(Self.uuidBlob(rowID)),
                    entityID2: Self.emptySecondaryEntityID
                )
            )
        }

        for (key, row) in snapshot.documentRowsByKey {
            append(key: key, tableName: "MyDocument", rowID: row.id)
        }
        for (key, row) in snapshot.pageRowsByKey {
            append(key: key, tableName: "MyDocumentPage", rowID: row.id)
        }
        for (key, row) in snapshot.pageContentRowsByKey {
            append(key: key, tableName: "MyDocumentPageContent", rowID: row.pageId)
        }
        for (key, row) in snapshot.aiPageCacheEntryRowsByKey {
            append(key: key, tableName: "AiPageCacheEntry", rowID: row.pageId)
        }

        return identities.sorted { $0.key < $1.key }
    }

    /**
     Reads the durable accepted My Documents generation when one has been published.

     - Parameter settingsStore: Local settings store containing synchronization metadata.
     - Returns: Stored accepted generation, or `nil` before first publication.
     - Side effects: Reads one settings row.
     - Failure modes: Throws `invalidStoredBaseline` for malformed persisted JSON; settings fetch
       failures invalidate an enclosing atomic batch.
     */
    func storedAcceptedBaseline(
        settingsStore: SettingsStore
    ) throws -> RemoteSyncMyDocumentAcceptedBaseline? {
        guard let payload = settingsStore.getString(Self.acceptedBaselineKey) else {
            return nil
        }
        guard let data = payload.data(using: .utf8),
              let baseline = try? JSONDecoder().decode(RemoteSyncMyDocumentAcceptedBaseline.self, from: data) else {
            throw RemoteSyncMyDocumentAcceptedBaselineError.invalidStoredBaseline
        }
        return baseline
    }

    /**
     Verifies that an outbox was projected from the currently accepted My Documents generation.

     - Parameters:
       - expectedRevision: Revision captured during strict preflight, including `nil` for legacy baselines.
       - expectedBaselineExists: Whether strict preflight observed an accepted baseline row.
       - settingsStore: Store containing the current accepted generation.
     - Side effects: Reads one settings row.
     - Failure modes: Throws for malformed state or when another generation replaced the baseline.
     */
    func validateAcceptedBaselineRevision(
        expectedRevision: UUID?,
        expectedBaselineExists: Bool,
        settingsStore: SettingsStore
    ) throws {
        let currentBaseline = try storedAcceptedBaseline(settingsStore: settingsStore)
        guard (currentBaseline != nil) == expectedBaselineExists,
              currentBaseline?.revision == expectedRevision else {
            throw RemoteSyncMyDocumentAcceptedBaselineError.staleAcceptedBaseline
        }
    }

    /**
     Publishes an already-projected My Documents generation without re-reading SwiftData.

     - Parameters:
       - baseline: Immutable fingerprints and row identities from the accepted generation.
       - settingsStore: Store receiving fingerprint and accepted-key mutations.
     - Side effects: Replaces all My Documents fingerprints and the accepted-key manifest.
     - Failure modes: Throws for an out-of-namespace fingerprint key or encoding failure; settings
       failures invalidate an enclosing `SettingsStore.performAtomicBatch`.
     */
    func acceptBaseline(
        _ baseline: RemoteSyncMyDocumentAcceptedBaseline,
        settingsStore: SettingsStore
    ) throws {
        let fingerprintStore = RemoteSyncRowFingerprintStore(settingsStore: settingsStore)
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let fingerprintPrefix = fingerprintStore.prefix(for: .myDocuments)
        let logPrefix = logEntryStore.prefix(for: .myDocuments)

        fingerprintStore.clearCategory(.myDocuments)
        for (logKey, fingerprint) in baseline.fingerprintsByKey.sorted(by: { $0.key < $1.key }) {
            guard logKey.hasPrefix(logPrefix) else {
                throw RemoteSyncMyDocumentAcceptedBaselineError.invalidFingerprintKey(logKey)
            }
            let suffix = String(logKey.dropFirst(logPrefix.count))
            settingsStore.setString("\(fingerprintPrefix)\(suffix)", value: fingerprint)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(baseline)
        guard let payload = String(data: data, encoding: .utf8) else {
            throw RemoteSyncMyDocumentAcceptedBaselineError.invalidStoredBaseline
        }
        settingsStore.setString(Self.acceptedBaselineKey, value: payload)
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
