// RemoteSyncMutationJournalService.swift -- Mutation-time Android LogEntry journaling

import Foundation
import SwiftData

/**
 One pending local mutation paired with the exact projected state that produced it.

 The Android `LogEntry` remains the conflict-resolution authority. The state fingerprint exists only
 to avoid assigning a new logical timestamp when an unrelated save observes the same already-dirty
 row again. A `nil` fingerprint represents a deleted row.
 */
struct RemoteSyncPendingMutation: Codable, Sendable, Equatable {
    /// Exact Android conflict row generated at the local mutation boundary.
    let entry: RemoteSyncLogEntry

    /// Stable current-row fingerprint, or `nil` when the mutation deleted the row.
    let stateFingerprint: String?
}

/** Typed failures raised when pending local mutation metadata cannot be trusted. */
enum RemoteSyncMutationJournalError: Error, Equatable {
    /// One pending-mutation settings payload is malformed.
    case malformedPendingMutation(storageKey: String)

    /// A marker's payload identity does not match the settings key containing it.
    case pendingMutationKeyMismatch(storageKey: String, expectedKey: String)

    /// A projected fingerprint has no corresponding Android row identity.
    case missingProjectedIdentity(category: RemoteSyncCategory, key: String)

    /// A deleted row has no accepted or pending identity from which to construct a delete log.
    case missingDeletedIdentity(category: RemoteSyncCategory, key: String)

    /// A pending marker no longer describes the exact row state being prepared for upload.
    case inconsistentPendingMutation(category: RemoteSyncCategory, key: String)
}

/** Canonical Android identity and accepted/current state used by the journal diff. */
private struct RemoteSyncMutationRowIdentity: Sendable, Equatable {
    let tableName: String
    let entityID1: RemoteSyncSQLiteValue
    let entityID2: RemoteSyncSQLiteValue
}

/** Complete current and accepted category projection at one local save boundary. */
private struct RemoteSyncMutationProjection {
    let currentFingerprints: [String: String]
    let currentRowsByKey: [String: RemoteSyncMutationRowIdentity]
    let acceptedFingerprints: [String: String]
    let acceptedRowsByKey: [String: RemoteSyncMutationRowIdentity]
    let suppressedKeys: Set<String>
}

/** One journal operation prepared before the shared logical timestamp is allocated. */
private struct RemoteSyncPreparedMutation {
    let key: String
    let identity: RemoteSyncMutationRowIdentity
    let type: RemoteSyncLogEntryType
    let stateFingerprint: String?
}

/**
 Records Android-compatible `LogEntry` rows when local stores persist user mutations.

 Android installs Room triggers on every syncable table, so pending changes exist before transport
 begins. iOS projects the same category graphs at each database-store save boundary, compares
 them with the last accepted generation, and writes deterministic local log entries in the same
 transaction as the graph/settings mutation. Upload acceptance can then merge a newer in-flight
 journal entry instead of replacing it with the generation that finished transport.

 Data dependencies:
 - category snapshot services provide exact Android row identities and fingerprints
 - accepted-generation manifests define the remote baseline, including rows with no initial log
 - `RemoteSyncLogEntryStore`, patch statuses, and progress cursors provide logical high-water marks
 - `RemoteSyncSettingsStore` supplies the stable local source-device identifier

 Side effects:
 - reads the complete current and accepted projection for one category
 - writes one local `LogEntry` and pending-state marker per newly observed mutation
 - may generate the stable local device identifier on its first invocation

 Failure modes:
 - strict snapshot, baseline, log, patch-status, and marker corruption aborts the caller's save
 - logical timestamp exhaustion fails visibly instead of wrapping signed 64-bit storage
 - incomplete row identity projections fail closed

 Concurrency:
 - this type follows the confinement of the supplied `ModelContext` and `SettingsStore`
 */
final class RemoteSyncMutationJournalService {
    private enum Keys {
        static let prefix = "remote_sync.pending_mutations"
    }

    private let nowProvider: () -> Int64
    private let readingPlanSnapshotService: RemoteSyncReadingPlanSnapshotService
    private let aiSettingsSnapshotService: RemoteSyncAISettingsSnapshotService
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /**
     Creates a mutation journal with exact category snapshot dependencies.

     - Parameters:
       - nowProvider: Android-compatible logical timestamp source.
       - readingPlanSnapshotService: Reading-plan projector bound to custom definition storage.
       - aiSettingsSnapshotService: AI projector bound to the device-local credential reader.
     - Side Effects: none until a category projection is requested.
     - Failure Modes: Construction cannot fail; strict projectors preserve their own failures.
     */
    init(
        nowProvider: @escaping () -> Int64 = { AndroidTimestamp.currentMilliseconds() },
        readingPlanSnapshotService: RemoteSyncReadingPlanSnapshotService = RemoteSyncReadingPlanSnapshotService(),
        aiSettingsSnapshotService: RemoteSyncAISettingsSnapshotService = RemoteSyncAISettingsSnapshotService()
    ) {
        self.nowProvider = nowProvider
        self.readingPlanSnapshotService = readingPlanSnapshotService
        self.aiSettingsSnapshotService = aiSettingsSnapshotService
        encoder.outputFormatting = [.sortedKeys]
    }

    /**
     Saves one staged graph mutation with its category journal when the container includes settings.

     Lightweight store tests intentionally construct graph-only schemas. Those contexts retain the
     historical direct-save behavior because no `Setting` entity exists in which a journal could be
     persisted. Production's model container always includes `Setting`.

     - Parameters:
       - category: Remote-sync category mutated by the database store.
       - modelContext: Context containing the already-staged graph mutation.
       - aiSettingsSnapshotService: AI projector bound to the caller's credential reader.
     - Side Effects:
       - processes pending SwiftData changes so strict snapshot fetches exclude staged deletions
       - commits graph and journal together, or directly saves graph-only test schemas
     - Throws: Rethrows strict journal validation and SwiftData persistence failures.
     */
    static func savePendingGraphChanges(
        for category: RemoteSyncCategory,
        modelContext: ModelContext,
        aiSettingsSnapshotService: RemoteSyncAISettingsSnapshotService = RemoteSyncAISettingsSnapshotService()
    ) throws {
        guard modelContext.container.schema.entitiesByName["Setting"] != nil else {
            try modelContext.save()
            return
        }

        let settingsStore = SettingsStore(modelContext: modelContext)
        modelContext.processPendingChanges()
        let journal = RemoteSyncMutationJournalService(
            aiSettingsSnapshotService: aiSettingsSnapshotService
        )
        let stagedDeletedIdentities = try journal.stagedDeletedIdentities(
            for: category,
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        try settingsStore.performJournaledSave(in: modelContext) {
            try journal.recordLocalChanges(
                for: category,
                modelContext: modelContext,
                settingsStore: settingsStore,
                stagedDeletedIdentities: stagedDeletedIdentities
            )
        }
    }

    /**
     Records local changes for one graph-backed or settings-backed category.

     - Parameters:
       - category: Category whose current projection should be compared with its accepted baseline.
       - modelContext: Graph context for bookmarks, workspaces, reading plans, and My Documents;
         progress callers may pass `nil` because progress state is settings-backed.
       - settingsStore: Local settings store participating in the caller's journaled transaction.
     - Side Effects: Stages new log entries and pending-state markers for changed rows.
     - Throws: Strict projection, metadata validation, encoding, or timestamp-allocation failures.
     */
    func recordLocalChanges(
        for category: RemoteSyncCategory,
        modelContext: ModelContext?,
        settingsStore: SettingsStore
    ) throws {
        let stagedDeletedIdentities: [RemoteSyncMutationRowIdentity]
        if let modelContext {
            stagedDeletedIdentities = try self.stagedDeletedIdentities(
                for: category,
                modelContext: modelContext,
                settingsStore: settingsStore
            )
        } else {
            stagedDeletedIdentities = []
        }
        try recordLocalChanges(
            for: category,
            modelContext: modelContext,
            settingsStore: settingsStore,
            stagedDeletedIdentities: stagedDeletedIdentities
        )
    }

    /**
     Records one category using deletion identities captured before an enclosing SwiftData transaction.

     - Parameters:
       - category: Category whose current state is being journaled.
       - modelContext: Optional graph context used by non-progress categories.
       - settingsStore: Local settings store receiving log and pending-mutation rows.
       - stagedDeletedIdentities: Immutable Android identities captured before transaction entry.
     - Side Effects: Stages deterministic local log rows and pending-state markers.
     - Throws: Rethrows strict projection, metadata, encoding, and timestamp failures.
     */
    private func recordLocalChanges(
        for category: RemoteSyncCategory,
        modelContext: ModelContext?,
        settingsStore: SettingsStore,
        stagedDeletedIdentities: [RemoteSyncMutationRowIdentity]
    ) throws {
        let projection = try projection(
            for: category,
            modelContext: modelContext,
            settingsStore: settingsStore,
            stagedDeletedIdentities: stagedDeletedIdentities
        )
        let sourceDevice = RemoteSyncSettingsStore(settingsStore: settingsStore).deviceIdentifier()
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let markers = try pendingMutations(for: category, settingsStore: settingsStore)

        var existingEntriesByKey: [String: RemoteSyncLogEntry] = [:]
        for rawEntry in try logEntryStore.entriesStrict(for: category) {
            let entry = category == .bookmarks
                ? AndroidBookmarkDatabaseContract.normalizedLogEntry(rawEntry)
                : rawEntry
            let key = logEntryStore.key(for: category, entry: entry)
            if existingEntriesByKey[key].map({
                RemoteSyncLogEntryConflictOrder.isNewer(entry, than: $0)
            }) ?? true {
                existingEntriesByKey[key] = entry
            }
        }

        let candidateKeys = Set(projection.currentRowsByKey.keys)
            .union(projection.acceptedRowsByKey.keys)
            .union(markers.keys)
            .subtracting(projection.suppressedKeys)
        var prepared: [RemoteSyncPreparedMutation] = []

        for key in candidateKeys.sorted() {
            let currentIdentity = projection.currentRowsByKey[key]
            let acceptedIdentity = projection.acceptedRowsByKey[key]
            let currentFingerprint = projection.currentFingerprints[key]
            let acceptedFingerprint = projection.acceptedFingerprints[key]
            let marker = markers[key]
            let currentExists = currentIdentity != nil
            let acceptedExists = acceptedIdentity != nil
            let matchesAccepted = currentExists == acceptedExists
                && (!currentExists || currentFingerprint == acceptedFingerprint)

            guard !matchesAccepted || marker != nil else {
                continue
            }
            if let marker, marker.stateFingerprint == currentFingerprint {
                continue
            }

            let identity: RemoteSyncMutationRowIdentity
            if let currentIdentity {
                identity = currentIdentity
            } else if let acceptedIdentity {
                identity = acceptedIdentity
            } else if let marker {
                identity = Self.identity(from: marker.entry)
            } else if let existing = existingEntriesByKey[key] {
                identity = Self.identity(from: existing)
            } else {
                throw RemoteSyncMutationJournalError.missingDeletedIdentity(
                    category: category,
                    key: key
                )
            }

            prepared.append(
                RemoteSyncPreparedMutation(
                    key: key,
                    identity: identity,
                    type: currentExists ? .upsert : .delete,
                    stateFingerprint: currentFingerprint
                )
            )
        }

        guard !prepared.isEmpty else {
            return
        }

        let statuses = try RemoteSyncPatchStatusStore(settingsStore: settingsStore)
            .statusesStrict(for: category)
        let progress = RemoteSyncStateStore(settingsStore: settingsStore)
            .progressState(for: category)
        let timestamp = try RemoteSyncLogicalSequence.nextTimestamp(
            now: nowProvider(),
            highWatermarks: existingEntriesByKey.values.map(\.lastUpdated)
                + markers.values.map(\.entry.lastUpdated)
                + statuses.map(\.appliedDate)
                + [progress.lastPatchWritten, progress.lastSynchronized].compactMap { $0 }
        )

        for mutation in prepared {
            let entry = RemoteSyncLogEntry(
                tableName: mutation.identity.tableName,
                entityID1: mutation.identity.entityID1,
                entityID2: mutation.identity.entityID2,
                type: mutation.type,
                lastUpdated: timestamp,
                sourceDevice: sourceDevice
            )
            try storePendingMutation(
                RemoteSyncPendingMutation(
                    entry: entry,
                    stateFingerprint: mutation.stateFingerprint
                ),
                key: mutation.key,
                category: category,
                settingsStore: settingsStore
            )
            try storeLogEntry(entry, category: category, settingsStore: settingsStore)
        }
    }

    /**
     Reads every pending local mutation with strict payload/key validation.

     - Parameters:
       - category: Category whose pending mutations should be read.
       - settingsStore: Local settings store containing the journal.
     - Returns: Pending mutations keyed by canonical Android log key.
     - Side Effects: Reads category-scoped settings rows.
     - Throws: `RemoteSyncMutationJournalError` for malformed or mismatched rows.
     */
    func pendingMutations(
        for category: RemoteSyncCategory,
        settingsStore: SettingsStore
    ) throws -> [String: RemoteSyncPendingMutation] {
        var result: [String: RemoteSyncPendingMutation] = [:]
        let prefix = markerPrefix(for: category)
        let logPrefix = RemoteSyncLogEntryStore(settingsStore: settingsStore).prefix(for: category)

        for stored in settingsStore.entries(withPrefix: prefix).sorted(by: { $0.key < $1.key }) {
            guard let data = stored.value.data(using: .utf8),
                  let marker = try? decoder.decode(RemoteSyncPendingMutation.self, from: data) else {
                throw RemoteSyncMutationJournalError.malformedPendingMutation(storageKey: stored.key)
            }
            let logKey = RemoteSyncLogEntryStore(settingsStore: settingsStore)
                .key(for: category, entry: marker.entry)
            let expectedStorageKey = markerKey(forLogKey: logKey, category: category, logPrefix: logPrefix)
            guard stored.key == expectedStorageKey else {
                throw RemoteSyncMutationJournalError.pendingMutationKeyMismatch(
                    storageKey: stored.key,
                    expectedKey: expectedStorageKey
                )
            }
            result[logKey] = marker
        }
        return result
    }

    /**
     Removes every pending mutation marker for a category without decoding abandoned payloads.

     Full remote restore and explicit reset replace or abandon the complete accepted generation, so
     no prior local marker remains meaningful. Raw prefix removal also lets reset recover from a
     malformed marker that strict synchronization would otherwise reject.

     - Parameters:
       - category: Category whose pending mutation generation is being abandoned.
       - settingsStore: Store containing category-scoped marker rows.
     - Side Effects: Removes every settings row under the category marker prefix.
     - Failure modes: None; settings removal is staged in the caller's transaction.
     */
    func clearPendingMutations(
        for category: RemoteSyncCategory,
        settingsStore: SettingsStore
    ) {
        for entry in settingsStore.entries(withPrefix: markerPrefix(for: category)) {
            settingsStore.remove(entry.key)
        }
    }

    /**
     Clears only pending mutations represented by an accepted full-backup snapshot.

     Initial upload can suspend after capturing its immutable archive. A marker is accepted only when
     its exact fingerprint matches both that archive and the current graph; later edits and deletions
     therefore survive as the next sparse generation.

     - Parameters:
       - acceptedFingerprints: Exact row fingerprints carried by the accepted initial backup.
       - category: Category whose initial generation was accepted.
       - modelContext: Current graph context, or the settings context for progress.
       - settingsStore: Store containing pending mutation markers.
     - Side Effects: Strictly reads current category state and removes only fully accepted markers.
     - Throws: Rethrows strict projection or marker decoding failures before caller commit.
     */
    func clearPendingMutationsAcceptedByBaseline(
        _ acceptedFingerprints: [String: String],
        for category: RemoteSyncCategory,
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws {
        let currentFingerprints = try projection(
            for: category,
            modelContext: category == .progress ? nil : modelContext,
            settingsStore: settingsStore,
            stagedDeletedIdentities: []
        ).currentFingerprints
        let markers = try pendingMutations(for: category, settingsStore: settingsStore)
        let logPrefix = RemoteSyncLogEntryStore(settingsStore: settingsStore).prefix(for: category)

        for (key, marker) in markers {
            guard marker.stateFingerprint == acceptedFingerprints[key],
                  currentFingerprints[key] == acceptedFingerprints[key] else {
                continue
            }
            settingsStore.remove(
                markerKey(forLogKey: key, category: category, logPrefix: logPrefix)
            )
        }
    }

    /**
     Resolves the mutation-time log row for one exact outbound row generation.

     - Parameters:
       - key: Canonical Android log key for the projected row.
       - stateFingerprint: Exact current fingerprint, or `nil` for a deletion.
       - type: Operation required by the sparse patch.
       - category: Category owning the mutation.
       - pendingMutations: Strictly decoded category journal.
     - Returns: The mutation-time entry, or `nil` for legacy dirty state without a journal marker.
     - Side Effects: None.
     - Throws: `inconsistentPendingMutation` when a marker exists but does not describe this exact
       state and operation. Failing closed prevents transport from silently restamping stale state.
     */
    func entryForUpload(
        key: String,
        stateFingerprint: String?,
        type: RemoteSyncLogEntryType,
        category: RemoteSyncCategory,
        pendingMutations: [String: RemoteSyncPendingMutation]
    ) throws -> RemoteSyncLogEntry? {
        guard let pendingMutation = pendingMutations[key] else {
            return nil
        }
        guard pendingMutation.stateFingerprint == stateFingerprint,
              pendingMutation.entry.type == type else {
            throw RemoteSyncMutationJournalError.inconsistentPendingMutation(
                category: category,
                key: key
            )
        }
        return pendingMutation.entry
    }

    /**
     Merges one accepted outbox generation with journals written while transport was suspended.

     - Parameters:
       - acceptedEntries: Full log generation captured by the durable outbox.
       - uploadedEntries: Sparse log rows actually carried by that outbox archive.
       - acceptedFingerprints: Exact row fingerprints carried by the accepted generation.
       - currentFingerprints: Fresh local projection at acceptance time.
       - category: Category being accepted.
       - settingsStore: Store receiving merged logs and marker cleanup.
     - Side Effects: Replaces log rows with deterministic winners and clears only markers whose
       exact state and log entry were accepted.
     - Throws: Strict log/marker validation errors.
     */
    func mergeAcceptedLogEntries(
        acceptedEntries: [RemoteSyncLogEntry],
        uploadedEntries: [RemoteSyncLogEntry],
        acceptedFingerprints: [String: String],
        currentFingerprints: [String: String],
        category: RemoteSyncCategory,
        settingsStore: SettingsStore
    ) throws {
        let logStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        var mergedByKey: [String: RemoteSyncLogEntry] = [:]

        for rawEntry in acceptedEntries + (try logStore.entriesStrict(for: category)) {
            let entry = category == .bookmarks
                ? AndroidBookmarkDatabaseContract.normalizedLogEntry(rawEntry)
                : rawEntry
            let key = logStore.key(for: category, entry: entry)
            if mergedByKey[key].map({
                RemoteSyncLogEntryConflictOrder.isNewer(entry, than: $0)
            }) ?? true {
                mergedByKey[key] = entry
            }
        }
        logStore.replaceEntries(
            mergedByKey.values.sorted(by: RemoteSyncLogEntryConflictOrder.precedes),
            for: category
        )

        let markers = try pendingMutations(for: category, settingsStore: settingsStore)
        for rawEntry in uploadedEntries {
            let entry = category == .bookmarks
                ? AndroidBookmarkDatabaseContract.normalizedLogEntry(rawEntry)
                : rawEntry
            let key = logStore.key(for: category, entry: entry)
            guard markers[key]?.entry == entry,
                  mergedByKey[key] == entry,
                  currentFingerprints[key] == acceptedFingerprints[key] else {
                continue
            }
            settingsStore.remove(markerStorageKey(forLogKey: key, category: category, settingsStore: settingsStore))
        }
    }

    /** Builds one complete category projection from existing snapshot and baseline services. */
    private func projection(
        for category: RemoteSyncCategory,
        modelContext: ModelContext?,
        settingsStore: SettingsStore,
        stagedDeletedIdentities: [RemoteSyncMutationRowIdentity]
    ) throws -> RemoteSyncMutationProjection {
        switch category {
        case .bookmarks:
            guard let modelContext else {
                throw SettingsStoreAtomicBatchError.modelContextMismatch
            }
            let service = RemoteSyncBookmarkSnapshotService()
            let snapshot = try service.snapshotCurrentStateThrowing(
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            let current = try service.acceptedBaselineThrowing(from: snapshot, preserving: nil)
            let accepted = try service.storedAcceptedBaseline(settingsStore: settingsStore)
            return excludingStagedDeletions(
                from: RemoteSyncMutationProjection(
                    currentFingerprints: snapshot.fingerprintsByKey,
                    currentRowsByKey: Dictionary(uniqueKeysWithValues: current.rowIdentities.map {
                        ($0.key, Self.identity(from: $0))
                    }),
                    acceptedFingerprints: accepted?.fingerprintsByKey ?? [:],
                    acceptedRowsByKey: Dictionary(uniqueKeysWithValues: (accepted?.rowIdentities ?? []).map {
                        ($0.key, Self.identity(from: $0))
                    }),
                    suppressedKeys: snapshot.suppressedKeys
                ),
                stagedDeletedIdentities: stagedDeletedIdentities
            )

        case .readingPlans:
            guard let modelContext else {
                throw SettingsStoreAtomicBatchError.modelContextMismatch
            }
            let service = readingPlanSnapshotService
            let snapshot = try service.snapshotCurrentStateStrict(
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            try service.validateExportableFingerprints(in: snapshot)
            let current = service.acceptedGeneration(from: snapshot)
            let accepted = try service.storedAcceptedBaseline(settingsStore: settingsStore)?.generation
            return excludingStagedDeletions(
                from: Self.projection(
                    currentFingerprints: snapshot.fingerprintsByKey,
                    currentRows: current.rowsByKey,
                    acceptedFingerprints: accepted?.fingerprintsByKey ?? [:],
                    acceptedRows: accepted?.rowsByKey ?? [:],
                    suppressedKeys: snapshot.suppressedKeys
                ),
                stagedDeletedIdentities: stagedDeletedIdentities
            )

        case .workspaces:
            guard let modelContext else {
                throw SettingsStoreAtomicBatchError.modelContextMismatch
            }
            let service = RemoteSyncWorkspaceSnapshotService()
            let snapshot = try service.snapshotCurrentStateStrict(
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            try service.validateExportableFingerprints(in: snapshot)
            let current = service.acceptedGeneration(from: snapshot)
            let accepted = try service.storedAcceptedBaseline(settingsStore: settingsStore)?.generation
            return excludingStagedDeletions(
                from: Self.projection(
                    currentFingerprints: snapshot.fingerprintsByKey,
                    currentRows: current.rowsByKey,
                    acceptedFingerprints: accepted?.fingerprintsByKey ?? [:],
                    acceptedRows: accepted?.rowsByKey ?? [:],
                    suppressedKeys: snapshot.suppressedKeys
                ),
                stagedDeletedIdentities: stagedDeletedIdentities
            )

        case .myDocuments:
            guard let modelContext else {
                throw SettingsStoreAtomicBatchError.modelContextMismatch
            }
            let service = RemoteSyncMyDocumentSnapshotService()
            let snapshot = try service.snapshotCurrentStateThrowing(
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            let current = try service.acceptedBaselineThrowing(from: snapshot)
            let accepted = try service.storedAcceptedBaseline(settingsStore: settingsStore)
            return excludingStagedDeletions(
                from: RemoteSyncMutationProjection(
                    currentFingerprints: snapshot.fingerprintsByKey,
                    currentRowsByKey: Dictionary(uniqueKeysWithValues: current.rowIdentities.map {
                        ($0.key, Self.identity(from: $0))
                    }),
                    acceptedFingerprints: accepted?.fingerprintsByKey ?? [:],
                    acceptedRowsByKey: Dictionary(uniqueKeysWithValues: (accepted?.rowIdentities ?? []).map {
                        ($0.key, Self.identity(from: $0))
                    }),
                    suppressedKeys: []
                ),
                stagedDeletedIdentities: stagedDeletedIdentities
            )

        case .progress:
            let service = RemoteSyncProgressSnapshotService()
            let snapshot = try service.snapshotCurrentStateStrict(settingsStore: settingsStore)
            try service.validateExportableFingerprints(in: snapshot)
            let current = service.acceptedGeneration(from: snapshot)
            let accepted = try service.storedAcceptedBaseline(settingsStore: settingsStore)?.generation
            return Self.projection(
                currentFingerprints: snapshot.fingerprintsByKey,
                currentRows: current.rowsByKey,
                acceptedFingerprints: accepted?.fingerprintsByKey ?? [:],
                acceptedRows: accepted?.rowsByKey ?? [:],
                suppressedKeys: snapshot.suppressedKeys
            )

        case .aiSettings:
            guard let modelContext else {
                throw SettingsStoreAtomicBatchError.modelContextMismatch
            }
            let snapshot = try aiSettingsSnapshotService.snapshotCurrentStateStrict(
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            let current = try aiSettingsSnapshotService.acceptedBaseline(from: snapshot)
            let accepted = try aiSettingsSnapshotService.storedAcceptedBaseline(
                settingsStore: settingsStore
            )
            return excludingStagedDeletions(
                from: RemoteSyncMutationProjection(
                    currentFingerprints: snapshot.fingerprintsByKey,
                    currentRowsByKey: Dictionary(uniqueKeysWithValues: current.rowIdentities.map {
                        ($0.key, Self.identity(from: $0))
                    }),
                    acceptedFingerprints: accepted?.fingerprintsByKey ?? [:],
                    acceptedRowsByKey: Dictionary(uniqueKeysWithValues: (accepted?.rowIdentities ?? []).map {
                        ($0.key, Self.identity(from: $0))
                    }),
                    suppressedKeys: []
                ),
                stagedDeletedIdentities: stagedDeletedIdentities
            )
        }
    }

    /**
     Removes accepted rows that SwiftData still returns while their deletion is staged.

     SwiftData fetches can include deleted models until the surrounding transaction commits. The
     journal must nevertheless observe the post-mutation graph so it can persist Android's delete
     trigger result in that same commit. Only identities present in the accepted baseline are
     removed; an insert deleted before publication therefore remains a local no-op.

     - Parameters:
       - projection: Current and accepted Android row projection before deletion correction.
       - stagedDeletedIdentities: Android identities captured before transaction entry.
     - Returns: Projection whose current side excludes exact staged-deleted Android identities.
     - Side Effects: Reads staged SwiftData deletions and local alias/status metadata.
     - Failure Modes: Unrecognized non-syncable model deletions are ignored; strict projection and
       metadata failures have already been surfaced by the caller.
     */
    private func excludingStagedDeletions(
        from projection: RemoteSyncMutationProjection,
        stagedDeletedIdentities: [RemoteSyncMutationRowIdentity]
    ) -> RemoteSyncMutationProjection {
        guard !stagedDeletedIdentities.isEmpty else {
            return projection
        }

        let deletedKeys = Set(projection.acceptedRowsByKey.compactMap { key, identity in
            stagedDeletedIdentities.contains(identity) ? key : nil
        })
        guard !deletedKeys.isEmpty else {
            return projection
        }

        return RemoteSyncMutationProjection(
            currentFingerprints: projection.currentFingerprints.filter { !deletedKeys.contains($0.key) },
            currentRowsByKey: projection.currentRowsByKey.filter { !deletedKeys.contains($0.key) },
            acceptedFingerprints: projection.acceptedFingerprints,
            acceptedRowsByKey: projection.acceptedRowsByKey,
            suppressedKeys: projection.suppressedKeys
        )
    }

    /**
     Converts staged SwiftData deletions into their canonical Android table identities.

     Parent rows intentionally yield only their own identity because Android Room foreign keys
     cascade dependent rows during replay. Direct child deletion yields the child identity so it
     remains independently journaled, matching Android's per-table trigger behavior.

     - Parameters:
       - category: Remote-sync category owning the deleted models.
       - modelContext: Context exposing the staged deletion registry.
       - settingsStore: Store used for label-id aliases and preserved reading-plan status ids.
     - Returns: Android row identities corresponding to syncable staged-deleted models.
     - Side Effects: Reads local alias and reading-plan status metadata.
     - Failure Modes: Models not represented by the category's Android schema produce no identity.
       Reading-plan status corruption throws before any graph or journal save.
     */
    private func stagedDeletedIdentities(
        for category: RemoteSyncCategory,
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws -> [RemoteSyncMutationRowIdentity] {
        let deletedModels = modelContext.deletedModelsArray
        var identities: [RemoteSyncMutationRowIdentity] = []

        /** Appends one UUID-keyed Android row identity. */
        func append(_ tableName: String, _ id: UUID, secondaryID: RemoteSyncSQLiteValue = .text("")) {
            identities.append(
                RemoteSyncMutationRowIdentity(
                    tableName: tableName,
                    entityID1: .blob(RemoteSyncBookmarkSnapshotService.uuidBlob(id)),
                    entityID2: secondaryID
                )
            )
        }

        switch category {
        case .bookmarks:
            let aliases = RemoteSyncBookmarkLabelAliasStore(settingsStore: settingsStore).allAliases()

            /** Returns every Android id that maps onto one local label id. */
            func remoteLabelIDs(for localID: UUID) -> Set<UUID> {
                Set([localID] + aliases.compactMap {
                    $0.localLabelID == localID ? $0.remoteLabelID : nil
                })
            }

            for model in deletedModels {
                switch model {
                case let row as Label:
                    for labelID in remoteLabelIDs(for: row.id) {
                        append("Label", labelID)
                    }
                case let row as BibleBookmark:
                    append("BibleBookmark", row.id)
                case let row as BibleBookmarkNotes:
                    append("BibleBookmarkNotes", row.bookmarkId)
                case let row as BibleBookmarkToLabel:
                    guard let bookmarkID = row.bookmark?.id,
                          let localLabelID = row.label?.id else { continue }
                    for labelID in remoteLabelIDs(for: localLabelID) {
                        append(
                            "BibleBookmarkToLabel",
                            bookmarkID,
                            secondaryID: .blob(RemoteSyncBookmarkSnapshotService.uuidBlob(labelID))
                        )
                    }
                case let row as GenericBookmark:
                    append("GenericBookmark", row.id)
                case let row as GenericBookmarkNotes:
                    append("GenericBookmarkNotes", row.bookmarkId)
                case let row as GenericBookmarkToLabel:
                    guard let bookmarkID = row.bookmark?.id,
                          let localLabelID = row.label?.id else { continue }
                    for labelID in remoteLabelIDs(for: localLabelID) {
                        append(
                            "GenericBookmarkToLabel",
                            bookmarkID,
                            secondaryID: .blob(RemoteSyncBookmarkSnapshotService.uuidBlob(labelID))
                        )
                    }
                case let row as StudyPadTextEntry:
                    append("StudyPadTextEntry", row.id)
                case let row as StudyPadTextEntryText:
                    append("StudyPadTextEntryText", row.studyPadTextEntryId)
                default:
                    continue
                }
            }

        case .readingPlans:
            let statusStore = RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore)
            for model in deletedModels {
                switch model {
                case let row as ReadingPlan:
                    append("ReadingPlan", row.id)
                case let row as ReadingPlanDay:
                    guard let plan = row.plan else { continue }
                    let statusID = try statusStore.storedStatusStrict(
                        planCode: plan.planCode,
                        dayNumber: row.dayNumber
                    )?.remoteStatusID ?? RemoteSyncReadingPlanSnapshotService.syntheticStatusID(
                        planID: plan.id,
                        dayNumber: row.dayNumber
                    )
                    append("ReadingPlanStatus", statusID)
                default:
                    continue
                }
            }

        case .workspaces:
            for model in deletedModels {
                switch model {
                case let row as Workspace:
                    append("Workspace", row.id)
                case let row as Window:
                    append("Window", row.id)
                case let row as PageManager:
                    append("PageManager", row.id)
                default:
                    continue
                }
            }

        case .myDocuments:
            for model in deletedModels {
                switch model {
                case let row as MyDocument:
                    append("MyDocument", row.id)
                case let row as MyDocumentPage:
                    append("MyDocumentPage", row.id)
                case let row as MyDocumentPageContent:
                    append("MyDocumentPageContent", row.pageId)
                case let row as AiPageCacheEntry:
                    append("AiPageCacheEntry", row.pageId)
                default:
                    continue
                }
            }

        case .progress:
            break

        case .aiSettings:
            for model in deletedModels {
                switch model {
                case let row as LLMProviderConfig:
                    append("LlmProviderConfig", row.id)
                case let row as LLMConfiguredModel:
                    append("LlmConfiguredModel", row.id)
                case let row as AgentPrompt:
                    append("AgentPrompt", row.id)
                case let row as GlobalAISettings:
                    append("GlobalAiSettings", row.id)
                case let row as LLMUsageRecord:
                    append("LlmUsageRecord", row.id)
                case let row as PromptCategory:
                    append("PromptCategory", row.id)
                case let row as BuiltInPromptOverride:
                    append("BuiltinPromptOverride", row.id)
                default:
                    continue
                }
            }
        }

        return identities
    }

    /** Adapts reading-plan accepted identities into the shared journal projection. */
    private static func projection(
        currentFingerprints: [String: String],
        currentRows: [String: RemoteSyncReadingPlanAcceptedRowIdentity],
        acceptedFingerprints: [String: String],
        acceptedRows: [String: RemoteSyncReadingPlanAcceptedRowIdentity],
        suppressedKeys: Set<String>
    ) -> RemoteSyncMutationProjection {
        RemoteSyncMutationProjection(
            currentFingerprints: currentFingerprints,
            currentRowsByKey: currentRows.mapValues(identity(from:)),
            acceptedFingerprints: acceptedFingerprints,
            acceptedRowsByKey: acceptedRows.mapValues(identity(from:)),
            suppressedKeys: suppressedKeys
        )
    }

    /** Adapts workspace accepted identities into the shared journal projection. */
    private static func projection(
        currentFingerprints: [String: String],
        currentRows: [String: RemoteSyncWorkspaceAcceptedRowIdentity],
        acceptedFingerprints: [String: String],
        acceptedRows: [String: RemoteSyncWorkspaceAcceptedRowIdentity],
        suppressedKeys: Set<String>
    ) -> RemoteSyncMutationProjection {
        RemoteSyncMutationProjection(
            currentFingerprints: currentFingerprints,
            currentRowsByKey: currentRows.mapValues(identity(from:)),
            acceptedFingerprints: acceptedFingerprints,
            acceptedRowsByKey: acceptedRows.mapValues(identity(from:)),
            suppressedKeys: suppressedKeys
        )
    }

    /** Adapts Progress accepted identities into the shared journal projection. */
    private static func projection(
        currentFingerprints: [String: String],
        currentRows: [String: RemoteSyncProgressAcceptedRowIdentity],
        acceptedFingerprints: [String: String],
        acceptedRows: [String: RemoteSyncProgressAcceptedRowIdentity],
        suppressedKeys: Set<String>
    ) -> RemoteSyncMutationProjection {
        RemoteSyncMutationProjection(
            currentFingerprints: currentFingerprints,
            currentRowsByKey: currentRows.mapValues(identity(from:)),
            acceptedFingerprints: acceptedFingerprints,
            acceptedRowsByKey: acceptedRows.mapValues(identity(from:)),
            suppressedKeys: suppressedKeys
        )
    }

    /** Stores one log row with throwing JSON encoding inside the caller's deferred-save scope. */
    private func storeLogEntry(
        _ entry: RemoteSyncLogEntry,
        category: RemoteSyncCategory,
        settingsStore: SettingsStore
    ) throws {
        let data = try encoder.encode(entry)
        settingsStore.setString(
            RemoteSyncLogEntryStore(settingsStore: settingsStore).key(for: category, entry: entry),
            value: String(decoding: data, as: UTF8.self)
        )
    }

    /** Stores one pending marker after validating its canonical Android identity key. */
    private func storePendingMutation(
        _ mutation: RemoteSyncPendingMutation,
        key: String,
        category: RemoteSyncCategory,
        settingsStore: SettingsStore
    ) throws {
        let logStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let canonicalKey = logStore.key(for: category, entry: mutation.entry)
        guard key == canonicalKey else {
            throw RemoteSyncMutationJournalError.pendingMutationKeyMismatch(
                storageKey: markerStorageKey(forLogKey: key, category: category, settingsStore: settingsStore),
                expectedKey: markerStorageKey(
                    forLogKey: canonicalKey,
                    category: category,
                    settingsStore: settingsStore
                )
            )
        }
        let data = try encoder.encode(mutation)
        settingsStore.setString(
            markerStorageKey(forLogKey: key, category: category, settingsStore: settingsStore),
            value: String(decoding: data, as: UTF8.self)
        )
    }

    /** Returns the category marker prefix ending in a dot. */
    private func markerPrefix(for category: RemoteSyncCategory) -> String {
        "\(Keys.prefix).\(category.rawValue)."
    }

    /** Converts one canonical log key into its pending-marker storage key. */
    private func markerStorageKey(
        forLogKey logKey: String,
        category: RemoteSyncCategory,
        settingsStore: SettingsStore
    ) -> String {
        let logPrefix = RemoteSyncLogEntryStore(settingsStore: settingsStore).prefix(for: category)
        return markerKey(forLogKey: logKey, category: category, logPrefix: logPrefix)
    }

    /** Converts one canonical log key into its pending-marker key with a known log prefix. */
    private func markerKey(
        forLogKey logKey: String,
        category: RemoteSyncCategory,
        logPrefix: String
    ) -> String {
        let suffix = logKey.hasPrefix(logPrefix) ? String(logKey.dropFirst(logPrefix.count)) : logKey
        return "\(markerPrefix(for: category))\(suffix)"
    }

    private static func identity(from entry: RemoteSyncLogEntry) -> RemoteSyncMutationRowIdentity {
        RemoteSyncMutationRowIdentity(
            tableName: entry.tableName,
            entityID1: entry.entityID1,
            entityID2: entry.entityID2
        )
    }

    private static func identity(
        from value: RemoteSyncBookmarkAcceptedRowIdentity
    ) -> RemoteSyncMutationRowIdentity {
        RemoteSyncMutationRowIdentity(
            tableName: value.tableName,
            entityID1: value.entityID1,
            entityID2: value.entityID2
        )
    }

    private static func identity(
        from value: RemoteSyncReadingPlanAcceptedRowIdentity
    ) -> RemoteSyncMutationRowIdentity {
        RemoteSyncMutationRowIdentity(
            tableName: value.tableName,
            entityID1: value.entityID1,
            entityID2: value.entityID2
        )
    }

    private static func identity(
        from value: RemoteSyncWorkspaceAcceptedRowIdentity
    ) -> RemoteSyncMutationRowIdentity {
        RemoteSyncMutationRowIdentity(
            tableName: value.tableName,
            entityID1: value.entityID1,
            entityID2: value.entityID2
        )
    }

    private static func identity(
        from value: RemoteSyncMyDocumentAcceptedRowIdentity
    ) -> RemoteSyncMutationRowIdentity {
        RemoteSyncMutationRowIdentity(
            tableName: value.tableName,
            entityID1: value.entityID1,
            entityID2: value.entityID2
        )
    }

    private static func identity(
        from value: RemoteSyncProgressAcceptedRowIdentity
    ) -> RemoteSyncMutationRowIdentity {
        RemoteSyncMutationRowIdentity(
            tableName: value.tableName,
            entityID1: value.entityID1,
            entityID2: value.entityID2
        )
    }

    /** Adapts one accepted AI settings identity into the shared journal projection. */
    private static func identity(
        from value: RemoteSyncAISettingsAcceptedRowIdentity
    ) -> RemoteSyncMutationRowIdentity {
        RemoteSyncMutationRowIdentity(
            tableName: value.tableName,
            entityID1: value.entityID1,
            entityID2: value.entityID2
        )
    }
}
