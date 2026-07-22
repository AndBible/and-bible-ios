// PersistedOrdinalTrustMigrationService.swift -- Fail-closed legacy ordinal repair

import Foundation
import SwiftData
import SwordKit

/**
 Result of resolving both endpoints of one legacy source range through an installed module.
 */
public enum PersistedOrdinalSourceRangeResolution: Sendable, Equatable {
    /// The module is not installed yet, so migration should retain a retryable pending state.
    case moduleUnavailable

    /// The module exists but its versification or one endpoint cannot be resolved exactly.
    case unresolved

    /// Both source ordinals resolved exactly in one known source versification.
    case resolved(start: VerseKeyReference, end: VerseKeyReference, sourceVersification: String)
}

/**
 Resolves legacy module-local ordinal ranges without assuming a versification from stored numbers.
 */
public protocol PersistedOrdinalSourceRangeResolving {
    /**
     Resolves both endpoints against the exact installed source module.

     - Parameters:
       - moduleInitials: Persisted source module initials.
       - startOrdinal: Source-module start ordinal.
       - endOrdinal: Source-module end ordinal.
     - Returns: Exact range metadata, a retryable missing-module result, or an unrecoverable result.
     - Side effects: Implementations may read installed module metadata and temporarily move a
       SWORD module cursor while resolving each endpoint.
     - Failure modes: Implementations report failures in the result instead of throwing.
     */
    func resolveSourceRange(
        moduleInitials: String,
        startOrdinal: Int,
        endOrdinal: Int
    ) -> PersistedOrdinalSourceRangeResolution
}

/**
 Resolves legacy source ordinals through the installed SWORD module inventory.
 */
public final class SwordPersistedOrdinalSourceRangeResolver: PersistedOrdinalSourceRangeResolving {
    private let manager: SwordManager?

    /**
     Creates a resolver using SWORD's configured module directory.

     - Parameter manager: Optional prebuilt manager, primarily for app startup reuse and tests.
     - Side effects: Creates a `SwordManager` when one is not supplied.
     - Failure modes: Failure to create a manager is retained and later reported as module unavailable.
     */
    public init(manager: SwordManager? = nil) {
        self.manager = manager ?? SwordManager()
    }

    /**
     Resolves both legacy endpoints through one installed module and one supported versification.

     - Parameters:
       - moduleInitials: Exact installed module initials.
       - startOrdinal: Source-module start ordinal.
       - endOrdinal: Source-module end ordinal.
     - Returns: Exact source references, a retryable missing-module result, or unresolved for bad
       ordinals and unknown module versification metadata.
     - Side effects: Looks up the installed module and temporarily moves its SWORD cursor twice.
     - Failure modes: No error is thrown; invalid metadata returns `.unresolved`.
     */
    public func resolveSourceRange(
        moduleInitials: String,
        startOrdinal: Int,
        endOrdinal: Int
    ) -> PersistedOrdinalSourceRangeResolution {
        guard let manager,
              let module = manager.module(named: moduleInitials) else {
            return .moduleUnavailable
        }
        let sourceVersification = VersificationMapper.versificationName(for: module)
        guard PersistedOrdinalTrustPolicy.normalizedKnownVersification(sourceVersification) != nil,
              let start = module.verseReference(ordinal: startOrdinal),
              let end = module.verseReference(ordinal: endOrdinal) else {
            return .unresolved
        }
        return .resolved(start: start, end: end, sourceVersification: sourceVersification)
    }
}

/**
 Summarizes one idempotent persisted-ordinal migration pass.
 */
public struct PersistedOrdinalTrustMigrationReport: Sendable, Equatable {
    /// Legacy Bible bookmarks repaired through strict source-to-KJVA mapping.
    public let repairedBookmarkCount: Int

    /// Legacy memorized-verse rows repaired through strict source-to-KJVA mapping.
    public let repairedMemorizedVerseCount: Int

    /// Legacy memorization-target rows repaired atomically at both endpoints.
    public let repairedMemorizationTargetCount: Int

    /// Rows left pending because their exact source modules are not installed.
    public let pendingModuleCount: Int

    /// Rows retained in a non-consumable unresolved state.
    public let unresolvedCount: Int

    /// Whether this pass changed any durable row or trust metadata.
    public let didChangePersistence: Bool

    /**
     Creates a migration summary.

     - Parameters:
       - repairedBookmarkCount: Number of repaired Bible bookmarks.
       - repairedMemorizedVerseCount: Number of repaired memorized-verse rows.
       - repairedMemorizationTargetCount: Number of repaired target rows.
       - pendingModuleCount: Number of rows still awaiting an installed module.
       - unresolvedCount: Number of rows currently quarantined as unresolved.
       - didChangePersistence: Whether the pass changed durable state.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        repairedBookmarkCount: Int,
        repairedMemorizedVerseCount: Int,
        repairedMemorizationTargetCount: Int,
        pendingModuleCount: Int,
        unresolvedCount: Int,
        didChangePersistence: Bool
    ) {
        self.repairedBookmarkCount = repairedBookmarkCount
        self.repairedMemorizedVerseCount = repairedMemorizedVerseCount
        self.repairedMemorizationTargetCount = repairedMemorizationTargetCount
        self.pendingModuleCount = pendingModuleCount
        self.unresolvedCount = unresolvedCount
        self.didChangePersistence = didChangePersistence
    }
}

/**
 Repairs legacy persisted ordinals after SWORD and SwiftData initialization and before remote sync.

 A row is repaired only from exact module initials, exact source ordinals, the module's actual
 supported versification, and strict mapping output. Missing modules remain retryable; all other
 provenance failures remain durable but quarantined.
 */
public final class PersistedOrdinalTrustMigrationService {
    private enum MigrationOutcome: Equatable {
        case unchanged
        case repaired
        case pending
        case unresolved
    }

    private let modelContext: ModelContext
    private let memorizationStore: MemorizationProgressStore
    private let sourceResolver: any PersistedOrdinalSourceRangeResolving

    /**
     Creates a migration service for one initialized persistence runtime.

     - Parameters:
       - modelContext: SwiftData context containing bookmarks and local settings rows.
       - settingsStore: Settings store bound to the same context.
       - sourceResolver: Resolver used to inspect exact installed source modules.
     - Side effects: none during initialization.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        sourceResolver: any PersistedOrdinalSourceRangeResolving = SwordPersistedOrdinalSourceRangeResolver()
    ) {
        self.modelContext = modelContext
        self.memorizationStore = MemorizationProgressStore(settingsStore: settingsStore)
        self.sourceResolver = sourceResolver
    }

    /**
     Runs one idempotent repair pass over bookmarks and memorization rows.

     - Returns: Counts for repaired, pending, and unresolved rows plus whether persistence changed.
     - Side effects:
       - fetches and may update `BibleBookmark` rows in `modelContext`
       - may rewrite memorization JSON while retaining every quarantined row
       - saves the supplied `ModelContext` when any durable state changes
     - Failure modes: Rethrows SwiftData fetch or save errors. Source lookup and mapping failures are
       represented as pending or unresolved trust states instead of being thrown.
     */
    public func migrate() throws -> PersistedOrdinalTrustMigrationReport {
        let bookmarks = try modelContext.fetch(FetchDescriptor<BibleBookmark>())
        var repairedBookmarkCount = 0
        var repairedMemorizedVerseCount = 0
        var repairedMemorizationTargetCount = 0
        var didChange = false

        for bookmark in bookmarks {
            let outcome = migrate(bookmark: bookmark)
            didChange = didChange || outcome != .unchanged
            if outcome == .repaired {
                repairedBookmarkCount += 1
            }
        }

        let requiresMemorizationBackfill = memorizationStore.requiresOrdinalTrustMetadataBackfill()
        let originalMemorization = try memorizationStore.persistenceSnapshotStrict()
        let migratedVerses = originalMemorization.memorizedVerses.map { row -> MemorizedVerseProgress in
            let result = migrate(memorizedVerse: row)
            if result.outcome == .repaired {
                repairedMemorizedVerseCount += 1
            }
            return result.row
        }
        let migratedTargets = originalMemorization.targetRows.map { row -> MemorizationTargetRow in
            let result = migrate(target: row)
            if result.outcome == .repaired {
                repairedMemorizationTargetCount += 1
            }
            return result.row
        }
        let migratedMemorization = MemorizationProgressSnapshot(
            memorizedVerses: migratedVerses,
            targetRows: migratedTargets
        )
        if requiresMemorizationBackfill || migratedMemorization != originalMemorization {
            try memorizationStore.replacePersistenceSnapshot(migratedMemorization)
            didChange = true
        }

        if didChange {
            try modelContext.save()
        }

        let persistedBookmarks = try modelContext.fetch(FetchDescriptor<BibleBookmark>())
        let persistedMemorization = memorizationStore.persistenceSnapshot()
        let pendingCount = persistedBookmarks.filter { $0.ordinalTrustState == .legacyPendingModule }.count
            + persistedMemorization.memorizedVerses.filter { $0.ordinalTrust.state == .legacyPendingModule }.count
            + persistedMemorization.targetRows.filter { $0.ordinalTrust.state == .legacyPendingModule }.count
        let unresolvedCount = persistedBookmarks.filter { !$0.hasTrustedPersistedOrdinals && $0.ordinalTrustState != .legacyPendingModule }.count
            + persistedMemorization.memorizedVerses.filter {
                !$0.hasTrustedPersistedOrdinals && $0.ordinalTrust.state != .legacyPendingModule
            }.count
            + persistedMemorization.targetRows.filter {
                !$0.hasTrustedPersistedOrdinals && $0.ordinalTrust.state != .legacyPendingModule
            }.count

        return PersistedOrdinalTrustMigrationReport(
            repairedBookmarkCount: repairedBookmarkCount,
            repairedMemorizedVerseCount: repairedMemorizedVerseCount,
            repairedMemorizationTargetCount: repairedMemorizationTargetCount,
            pendingModuleCount: pendingCount,
            unresolvedCount: unresolvedCount,
            didChangePersistence: didChange
        )
    }

    /**
     Migrates one legacy bookmark from the strongest provenance retained by the prior schema.

     Android-restored rows whose nullable `book` column remained empty already carry authoritative
     KJVA columns plus their source versification and ordinals. Those rows use Android's validated
     import contract directly; module-scoped rows continue through exact installed-module mapping.

     - Parameter bookmark: Mutable SwiftData row to inspect and, when provable, repair atomically at both endpoints.
     - Returns: Whether the row was unchanged, repaired, left pending, or quarantined unresolved.
     - Side effects: May replace the bookmark's KJVA endpoints, source versification, and trust fields in memory.
     - Failure modes: Missing modules remain pending; invalid Android KJVA data, missing identity,
       lying resolution, reversed ranges, and mapping failures become unresolved without throwing.
     */
    private func migrate(bookmark: BibleBookmark) -> MigrationOutcome {
        if bookmark.hasTrustedPersistedOrdinals {
            return .unchanged
        }
        if bookmark.ordinalTrustState.isVerified {
            let unresolved = unresolvedMetadata(
                from: bookmark.ordinalTrustMetadata,
                provenance: bookmark.ordinalProvenance
            )
            return update(bookmark: bookmark, metadata: unresolved) ? .unresolved : .unchanged
        }
        guard bookmark.ordinalTrustState == .legacyPendingModule else {
            return .unchanged
        }

        let initials = normalizedInitials(bookmark.bookInitials)
        let sourceStart = bookmark.ordinalSourceStart ?? bookmark.ordinalStart
        let sourceEnd = bookmark.ordinalSourceEnd ?? bookmark.ordinalEnd
        let legacyAndroidBook = bookmark.book?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasLegacyAndroidBook = legacyAndroidBook?.isEmpty == false
        if initials == nil, !hasLegacyAndroidBook {
            let metadata = PersistedOrdinalTrustPolicy.androidImportMetadata(
                sourceVersification: bookmark.v11n,
                sourceOrdinalStart: sourceStart,
                sourceOrdinalEnd: sourceEnd,
                kjvaOrdinalStart: bookmark.kjvOrdinalStart,
                kjvaOrdinalEnd: bookmark.kjvOrdinalEnd
            )
            let outcome: MigrationOutcome = PersistedOrdinalTrustPolicy.isTrustedKJVARange(
                metadata: metadata,
                start: bookmark.kjvOrdinalStart,
                end: bookmark.kjvOrdinalEnd
            ) ? .repaired : .unresolved
            return update(bookmark: bookmark, metadata: metadata) ? outcome : .unchanged
        }
        guard let initials else {
            let metadata = unresolvedMetadata(from: bookmark.ordinalTrustMetadata, provenance: .unknown)
            return update(bookmark: bookmark, metadata: metadata) ? .unresolved : .unchanged
        }

        switch sourceResolver.resolveSourceRange(
            moduleInitials: initials,
            startOrdinal: sourceStart,
            endOrdinal: sourceEnd
        ) {
        case .moduleUnavailable:
            let metadata = PersistedOrdinalTrustMetadata(
                state: .legacyPendingModule,
                mappingVersion: 0,
                provenance: .unknown,
                sourceBookInitials: initials,
                sourceVersification: nil,
                sourceOrdinalStart: sourceStart,
                sourceOrdinalEnd: sourceEnd
            )
            return update(bookmark: bookmark, metadata: metadata) ? .pending : .unchanged
        case .unresolved:
            let metadata = unresolvedMetadata(
                sourceBookInitials: initials,
                sourceVersification: nil,
                sourceOrdinalStart: sourceStart,
                sourceOrdinalEnd: sourceEnd,
                provenance: .legacyMigration
            )
            return update(bookmark: bookmark, metadata: metadata) ? .unresolved : .unchanged
        case let .resolved(start, end, sourceVersification):
            guard let verifiedRange = VerifiedKJVAOrdinalRange(
                sourceBookInitials: initials,
                sourceVersification: sourceVersification,
                sourceOrdinalStart: sourceStart,
                sourceOrdinalEnd: sourceEnd,
                sourceReferenceStart: start,
                sourceReferenceEnd: end
            ) else {
                let metadata = unresolvedMetadata(
                    sourceBookInitials: initials,
                    sourceVersification: sourceVersification,
                    sourceOrdinalStart: sourceStart,
                    sourceOrdinalEnd: sourceEnd,
                    provenance: .legacyMigration
                )
                return update(bookmark: bookmark, metadata: metadata) ? .unresolved : .unchanged
            }

            let metadata = verifiedMigrationMetadata(from: verifiedRange)
            bookmark.kjvOrdinalStart = verifiedRange.kjvaOrdinalStart
            bookmark.kjvOrdinalEnd = verifiedRange.kjvaOrdinalEnd
            bookmark.v11n = sourceVersification
            bookmark.ordinalTrustMetadata = metadata
            return .repaired
        }
    }

    /**
     Migrates one legacy memorized-verse row from its exact preserved module-local ordinal.

     - Parameter row: Durable memorized row to validate or repair.
     - Returns: A replacement row plus its migration outcome.
     - Side effects: Resolves an installed SWORD module and reads pinned mapping resources; persistence is deferred
       until the caller has prepared the complete snapshot.
     - Failure modes: Missing modules remain pending; ambiguous, non-exact, or non-single-verse mappings are
       retained as unresolved rows.
     */
    private func migrate(
        memorizedVerse row: MemorizedVerseProgress
    ) -> (row: MemorizedVerseProgress, outcome: MigrationOutcome) {
        if row.hasTrustedPersistedOrdinals {
            return (row, .unchanged)
        }
        if row.ordinalTrust.state.isVerified {
            return (
                replacing(row, metadata: unresolvedMetadata(from: row.ordinalTrust, provenance: row.ordinalTrust.provenance)),
                .unresolved
            )
        }
        guard row.ordinalTrust.state == .legacyPendingModule else {
            return (row, .unchanged)
        }

        let initials = normalizedInitials(row.ordinalTrust.sourceBookInitials ?? row.bookInitials)
        let sourceOrdinal = row.ordinalTrust.sourceOrdinalStart ?? row.kjvOrdinal
        guard let initials else {
            return (replacing(row, metadata: unresolvedMetadata(from: row.ordinalTrust, provenance: .unknown)), .unresolved)
        }

        switch sourceResolver.resolveSourceRange(
            moduleInitials: initials,
            startOrdinal: sourceOrdinal,
            endOrdinal: sourceOrdinal
        ) {
        case .moduleUnavailable:
            let pending = PersistedOrdinalTrustMetadata(
                state: .legacyPendingModule,
                mappingVersion: 0,
                provenance: .unknown,
                sourceBookInitials: initials,
                sourceVersification: nil,
                sourceOrdinalStart: sourceOrdinal,
                sourceOrdinalEnd: sourceOrdinal
            )
            let replacement = replacing(row, metadata: pending)
            return (replacement, replacement == row ? .unchanged : .pending)
        case .unresolved:
            return (
                replacing(
                    row,
                    metadata: unresolvedMetadata(
                        sourceBookInitials: initials,
                        sourceVersification: nil,
                        sourceOrdinalStart: sourceOrdinal,
                        sourceOrdinalEnd: sourceOrdinal,
                        provenance: .legacyMigration
                    )
                ),
                .unresolved
            )
        case let .resolved(start, end, sourceVersification):
            guard let verifiedRange = VerifiedKJVAOrdinalRange(
                sourceBookInitials: initials,
                sourceVersification: sourceVersification,
                sourceOrdinalStart: sourceOrdinal,
                sourceOrdinalEnd: sourceOrdinal,
                sourceReferenceStart: start,
                sourceReferenceEnd: end
            ),
            verifiedRange.kjvaOrdinalStart == verifiedRange.kjvaOrdinalEnd else {
                return (
                    replacing(
                        row,
                        metadata: unresolvedMetadata(
                            sourceBookInitials: initials,
                            sourceVersification: sourceVersification,
                            sourceOrdinalStart: sourceOrdinal,
                            sourceOrdinalEnd: sourceOrdinal,
                            provenance: .legacyMigration
                        )
                    ),
                    .unresolved
                )
            }
            return (
                MemorizedVerseProgress(
                    id: row.id,
                    bookInitials: "",
                    kjvOrdinal: verifiedRange.kjvaOrdinalStart,
                    memorizedAt: row.memorizedAt,
                    ordinalTrust: verifiedMigrationMetadata(from: verifiedRange)
                ),
                .repaired
            )
        }
    }

    /**
     Migrates one legacy memorization target only when both source endpoints resolve as one exact range.

     - Parameter row: Durable target row whose source range must be proven.
     - Returns: A replacement row plus its migration outcome.
     - Side effects: Resolves an installed SWORD module and reads pinned mapping resources; persistence is deferred
       until the caller has prepared every target row.
     - Failure modes: Missing modules remain pending; missing identity, reversed ranges, endpoint mismatch, and
       mapping failures retain the row in unresolved quarantine.
     */
    private func migrate(
        target row: MemorizationTargetRow
    ) -> (row: MemorizationTargetRow, outcome: MigrationOutcome) {
        if row.hasTrustedPersistedOrdinals {
            return (row, .unchanged)
        }
        if row.ordinalTrust.state.isVerified {
            return (
                replacing(row, metadata: unresolvedMetadata(from: row.ordinalTrust, provenance: row.ordinalTrust.provenance)),
                .unresolved
            )
        }
        guard row.ordinalTrust.state == .legacyPendingModule else {
            return (row, .unchanged)
        }

        let initials = normalizedInitials(row.ordinalTrust.sourceBookInitials ?? row.bookInitials)
        let sourceStart = row.ordinalTrust.sourceOrdinalStart ?? row.startOrdinal
        let sourceEnd = row.ordinalTrust.sourceOrdinalEnd ?? row.endOrdinal
        guard let initials else {
            return (replacing(row, metadata: unresolvedMetadata(from: row.ordinalTrust, provenance: .unknown)), .unresolved)
        }

        switch sourceResolver.resolveSourceRange(
            moduleInitials: initials,
            startOrdinal: sourceStart,
            endOrdinal: sourceEnd
        ) {
        case .moduleUnavailable:
            let pending = PersistedOrdinalTrustMetadata(
                state: .legacyPendingModule,
                mappingVersion: 0,
                provenance: .unknown,
                sourceBookInitials: initials,
                sourceVersification: nil,
                sourceOrdinalStart: sourceStart,
                sourceOrdinalEnd: sourceEnd
            )
            let replacement = replacing(row, metadata: pending)
            return (replacement, replacement == row ? .unchanged : .pending)
        case .unresolved:
            return (
                replacing(
                    row,
                    metadata: unresolvedMetadata(
                        sourceBookInitials: initials,
                        sourceVersification: nil,
                        sourceOrdinalStart: sourceStart,
                        sourceOrdinalEnd: sourceEnd,
                        provenance: .legacyMigration
                    )
                ),
                .unresolved
            )
        case let .resolved(start, end, sourceVersification):
            guard let verifiedRange = VerifiedKJVAOrdinalRange(
                sourceBookInitials: initials,
                sourceVersification: sourceVersification,
                sourceOrdinalStart: sourceStart,
                sourceOrdinalEnd: sourceEnd,
                sourceReferenceStart: start,
                sourceReferenceEnd: end
            ) else {
                return (
                    replacing(
                        row,
                        metadata: unresolvedMetadata(
                            sourceBookInitials: initials,
                            sourceVersification: sourceVersification,
                            sourceOrdinalStart: sourceStart,
                            sourceOrdinalEnd: sourceEnd,
                            provenance: .legacyMigration
                        )
                    ),
                    .unresolved
                )
            }
            return (
                MemorizationTargetRow(
                    id: row.id,
                    bookInitials: "",
                    startOrdinal: verifiedRange.kjvaOrdinalStart,
                    endOrdinal: verifiedRange.kjvaOrdinalEnd,
                    createdAt: row.createdAt,
                    ordinalTrust: verifiedMigrationMetadata(from: verifiedRange)
                ),
                .repaired
            )
        }
    }

    /**
     Copies a memorized row while replacing only its trust metadata.

     - Parameters:
       - row: Existing row whose stable identity, coordinate, and timestamp must be retained.
       - metadata: New pending or unresolved trust decision.
     - Returns: Value-equivalent row except for trust metadata.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func replacing(
        _ row: MemorizedVerseProgress,
        metadata: PersistedOrdinalTrustMetadata
    ) -> MemorizedVerseProgress {
        MemorizedVerseProgress(
            id: row.id,
            bookInitials: row.bookInitials,
            kjvOrdinal: row.kjvOrdinal,
            memorizedAt: row.memorizedAt,
            ordinalTrust: metadata
        )
    }

    /**
     Copies a target row while replacing only its trust metadata.

     - Parameters:
       - row: Existing target whose stable identity, range, and timestamp must be retained.
       - metadata: New pending or unresolved trust decision.
     - Returns: Value-equivalent row except for trust metadata.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func replacing(
        _ row: MemorizationTargetRow,
        metadata: PersistedOrdinalTrustMetadata
    ) -> MemorizationTargetRow {
        MemorizationTargetRow(
            id: row.id,
            bookInitials: row.bookInitials,
            startOrdinal: row.startOrdinal,
            endOrdinal: row.endOrdinal,
            createdAt: row.createdAt,
            ordinalTrust: metadata
        )
    }

    /**
     Applies bookmark trust metadata only when it differs from the durable fields already present.

     - Parameters:
       - bookmark: Mutable SwiftData bookmark row.
       - metadata: Replacement trust contract.
     - Returns: `true` when the row changed, otherwise `false` for idempotent passes.
     - Side effects: Mutates the bookmark's flattened trust fields in memory.
     - Failure modes: This helper cannot fail.
     */
    private func update(
        bookmark: BibleBookmark,
        metadata: PersistedOrdinalTrustMetadata
    ) -> Bool {
        guard bookmark.ordinalTrustMetadata != metadata else {
            return false
        }
        bookmark.ordinalTrustMetadata = metadata
        return true
    }

    /**
     Quarantines existing trust metadata while retaining every available source field.

     - Parameters:
       - metadata: Existing metadata whose verified claim could not be re-established.
       - provenance: Boundary that attempted or originally supplied the trust decision.
     - Returns: Unresolved metadata with mapping version zero.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func unresolvedMetadata(
        from metadata: PersistedOrdinalTrustMetadata,
        provenance: PersistedOrdinalProvenance
    ) -> PersistedOrdinalTrustMetadata {
        unresolvedMetadata(
            sourceBookInitials: metadata.sourceBookInitials,
            sourceVersification: metadata.sourceVersification,
            sourceOrdinalStart: metadata.sourceOrdinalStart,
            sourceOrdinalEnd: metadata.sourceOrdinalEnd,
            provenance: provenance
        )
    }

    /**
     Builds durable unresolved metadata from individually preserved source fields.

     - Parameters:
       - sourceBookInitials: Exact module initials when known.
       - sourceVersification: Exact supported source versification when known.
       - sourceOrdinalStart: Preserved source start ordinal when known.
       - sourceOrdinalEnd: Preserved source end ordinal when known.
       - provenance: Boundary that attempted or originally supplied the trust decision.
     - Returns: Non-consumable metadata retaining all supplied diagnostic coordinates.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func unresolvedMetadata(
        sourceBookInitials: String?,
        sourceVersification: String?,
        sourceOrdinalStart: Int?,
        sourceOrdinalEnd: Int?,
        provenance: PersistedOrdinalProvenance
    ) -> PersistedOrdinalTrustMetadata {
        PersistedOrdinalTrustMetadata(
            state: .legacyUnresolved,
            mappingVersion: 0,
            provenance: provenance,
            sourceBookInitials: sourceBookInitials,
            sourceVersification: sourceVersification,
            sourceOrdinalStart: sourceOrdinalStart,
            sourceOrdinalEnd: sourceOrdinalEnd
        )
    }

    /**
     Re-labels an already validated typed range as startup-migration provenance.

     - Parameter range: Strictly validated source-to-KJVA mapping result.
     - Returns: Mapping-version-one metadata with unchanged exact source coordinates and
       `legacyMigration` provenance.
     - Side effects: none.
     - Failure modes: This helper accepts only a constructed `VerifiedKJVAOrdinalRange`, so it cannot
       create trust from raw coordinates.
     */
    private func verifiedMigrationMetadata(
        from range: VerifiedKJVAOrdinalRange
    ) -> PersistedOrdinalTrustMetadata {
        PersistedOrdinalTrustMetadata(
            state: .verifiedMappingV1,
            mappingVersion: PersistedOrdinalTrustPolicy.currentMappingVersion,
            provenance: .legacyMigration,
            sourceBookInitials: range.ordinalTrust.sourceBookInitials,
            sourceVersification: range.ordinalTrust.sourceVersification,
            sourceOrdinalStart: range.ordinalTrust.sourceOrdinalStart,
            sourceOrdinalEnd: range.ordinalTrust.sourceOrdinalEnd
        )
    }

    /**
     Trims a legacy module identifier without inventing one for empty input.

     - Parameter rawValue: Persisted module-initial string.
     - Returns: Nonempty trimmed initials, or `nil` when no source identity exists.
     - Side effects: none.
     - Failure modes: Empty or whitespace-only values fail closed with `nil`.
     */
    private func normalizedInitials(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
