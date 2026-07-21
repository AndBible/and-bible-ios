// ModuleStoreTransactionPublisher+ExactOverlay.swift - Ordered exact-file overlays

import Foundation

extension ModuleStoreTransactionPublisher {
    /**
     Publishes arbitrary staged module-backup files as one exact-path overlay.

     This entry point supports Android module-backup families that do not use SWORD configs, while
     preserving the same conflict authorization, crash recovery, and publication ordering as a
     local SWORD overlay. Content is copied before activation files become discoverable.

     - Parameters:
       - manifest: Ordered content and activation paths rooted at the canonical module store.
       - stagingRootURL: Isolated root containing every manifest file.
       - authorizedExistingPaths: Exact live conflicts approved for this archive identity.
       - kind: Writer category for coordinator diagnostics.
       - onCommitStarted: Callback after validation closes cancellation and before live mutation.
       - validatePublishedState: Optional registration/availability validation performed after every
         activation file is live but before the module-store journal commits.
       - rollbackPublishedState: Idempotent inverse for external state changed by validation. It is
         invoked when validation or any later pre-commit operation fails.
       - completePublishedState: Nonthrowing cleanup invoked only after the journal commits.
     - Side effects: Overlays exact files, invalidates the module cache, and posts one terminal
       module-store notification after successful commit.
     - Throws: Unsafe/duplicate paths, missing staged files, unapproved or non-file destinations,
       filesystem failures, or rollback failures.
     - Important: Callers must bind `authorizedExistingPaths` to the archive digest presented during
       preflight. This transaction authorizes destinations, not archive identity.
     */
    public func publishExactOverlay(
        _ manifest: ModuleStoreExactOverlayManifest,
        from stagingRootURL: URL,
        authorizedExistingPaths: Set<String>,
        kind: ModuleStoreMutationKind,
        onCommitStarted: (() -> Void)? = nil,
        validatePublishedState: (() throws -> Void)? = nil,
        rollbackPublishedState: (() throws -> Void)? = nil,
        completePublishedState: (() -> Void)? = nil
    ) throws {
        try coordinator.withExclusiveTransaction(kind: kind, prepare: {
            let currentManifest = try revalidatedExactOverlay(
                manifest,
                from: stagingRootURL
            )
            try validateAuthorizedConflicts(
                for: currentManifest,
                authorizedExistingPaths: authorizedExistingPaths
            )
            return currentManifest
        }, commit: { currentManifest in
            onCommitStarted?()
            try performExactOverlay(
                manifest: currentManifest,
                stagingRootURL: stagingRootURL,
                validatePublishedState: validatePublishedState,
                rollbackPublishedState: rollbackPublishedState,
                completePublishedState: completePublishedState
            )
        })
    }

    /** Revalidates every exact overlay path and staged file under the transaction lease. */
    private func revalidatedExactOverlay(
        _ manifest: ModuleStoreExactOverlayManifest,
        from stagingRootURL: URL
    ) throws -> ModuleStoreExactOverlayManifest {
        guard !manifest.allRelativePaths.isEmpty else {
            throw ModuleStoreMutationError.missingPayload("<archive>")
        }
        let canonicalStagingRoot = stagingRootURL.standardizedFileURL.resolvingSymlinksInPath()
        try validateIsolatedStagingRoot(canonicalStagingRoot)

        var seenLexicalPaths: Set<String> = []
        var seenDestinationPaths: Set<String> = []
        for relativePath in manifest.allRelativePaths {
            try validateExactOverlayRelativePath(relativePath)
            guard seenLexicalPaths.insert(resolver.filesystemCollisionKey(relativePath)).inserted else {
                throw ModuleStoreMutationError.duplicatePath(relativePath)
            }
            let stagedURL = canonicalStagingRoot.appendingPathComponent(relativePath)
            try validateStagedFile(
                stagedURL,
                relativePath: relativePath,
                stagingRoot: canonicalStagingRoot
            )
            let destinationURL = canonicalRootURL.appendingPathComponent(relativePath)
            try resolver.validateCanonicalContainment(of: destinationURL, beneath: canonicalRootURL)
            let destinationKey = resolver.filesystemCollisionKey(
                destinationURL.standardizedFileURL.resolvingSymlinksInPath().path
            )
            guard seenDestinationPaths.insert(destinationKey).inserted else {
                throw ModuleStoreMutationError.duplicatePath(relativePath)
            }
        }
        return manifest
    }

    /** Rejects transaction metadata, cache files, traversal, and ambiguous path components. */
    private func validateExactOverlayRelativePath(_ relativePath: String) throws {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.hasSuffix("/"),
              !relativePath.contains("\\"),
              !relativePath.contains("\0") else {
            throw ModuleStoreMutationError.unsafeArchivePath(relativePath)
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw ModuleStoreMutationError.unsafeArchivePath(relativePath)
        }
        let first = resolver.filesystemCollisionKey(String(components[0]))
        let reservedTransactionRoot = first == ".module-recovery"
            || first.hasPrefix(".module-transaction-")
        let reservedCache = resolver.filesystemCollisionKey(relativePath)
            == "mods.d/modules-conf.cache"
        guard !reservedTransactionRoot, !reservedCache else {
            throw ModuleStoreMutationError.unsafeArchivePath(relativePath)
        }
    }

    /** Rechecks exact live conflicts and requires approval for every replaceable destination. */
    private func validateAuthorizedConflicts(
        for manifest: ModuleStoreExactOverlayManifest,
        authorizedExistingPaths: Set<String>
    ) throws {
        var liveConflicts: Set<String> = []
        var typeConflicts: [String] = []
        for relativePath in manifest.allRelativePaths {
            guard let existing = existingURL(relativePath: relativePath) else { continue }
            let values = try existing.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                typeConflicts.append(relativePath)
                continue
            }
            liveConflicts.insert(relativePath)
        }
        guard typeConflicts.isEmpty else {
            throw ModuleStoreMutationError.destinationTypeConflict(typeConflicts.sorted())
        }
        let approvedKeys = Set(authorizedExistingPaths.map(resolver.filesystemCollisionKey))
        let unapproved = liveConflicts.filter { relativePath in
            !approvedKeys.contains(resolver.filesystemCollisionKey(relativePath))
        }
        guard unapproved.isEmpty else {
            throw ModuleStoreMutationError.destinationFilesExist(liveConflicts.sorted())
        }
    }

    /** Commits a SWORD exact overlay through the shared ordered-file implementation. */
    func performSwordOverlay(
        plan: ModuleStoreStagedInstallPlan,
        stagingRootURL: URL
    ) throws {
        try performExactOverlay(
            manifest: ModuleStoreExactOverlayManifest(
                contentRelativePaths: plan.payloadRelativePaths,
                activationRelativePaths: plan.configurationRelativePaths
            ),
            stagingRootURL: stagingRootURL
        )
    }

    /**
     Commits a revalidated exact overlay with durable backup and publication intent.

     - Parameters:
       - manifest: Exact paths ordered as content first and activation last.
       - stagingRootURL: Isolated staging root containing every manifest file.
     - Side effects: Backs up conflicts, publishes files, synchronizes state, invalidates cache, and
       leaves a committed recovery journal when post-commit residue cleanup fails.
     - Throws: Filesystem errors or a combined rollback error when restoration also fails.
     - Note: The exclusive coordinator lease is held for this entire call.
     */
    private func performExactOverlay(
        manifest: ModuleStoreExactOverlayManifest,
        stagingRootURL: URL,
        validatePublishedState: (() throws -> Void)? = nil,
        rollbackPublishedState: (() throws -> Void)? = nil,
        completePublishedState: (() -> Void)? = nil
    ) throws {
        let canonicalStagingRoot = stagingRootURL.standardizedFileURL.resolvingSymlinksInPath()
        let backupRoot = canonicalRootURL.appendingPathComponent(
            ".module-transaction-\(UUID().uuidString).backup",
            isDirectory: true
        )
        var backupMoves: [BackupMove] = []
        var publishedURLs: [URL] = []
        var createdDirectories: [URL] = []
        var publishedStateValidationStarted = false
        let recoveryTransaction = try recoveryJournal.begin(backupRoot: backupRoot)

        do {
            for relativePath in manifest.contentRelativePaths {
                try publishExactOverlayFile(
                    relativePath: relativePath,
                    activation: false,
                    stagingRootURL: canonicalStagingRoot,
                    backupRoot: backupRoot,
                    recoveryTransaction: recoveryTransaction,
                    backupMoves: &backupMoves,
                    publishedURLs: &publishedURLs,
                    createdDirectories: &createdDirectories
                )
            }

            for relativePath in manifest.activationRelativePaths {
                try publishExactOverlayFile(
                    relativePath: relativePath,
                    activation: true,
                    stagingRootURL: canonicalStagingRoot,
                    backupRoot: backupRoot,
                    recoveryTransaction: recoveryTransaction,
                    backupMoves: &backupMoves,
                    publishedURLs: &publishedURLs,
                    createdDirectories: &createdDirectories
                )
            }

            if let validatePublishedState {
                try invalidateModuleCache()
                publishedStateValidationStarted = true
                try validatePublishedState()
            }
            try recoveryTransaction.synchronizePublishedState()
            try invalidateModuleCache()
            try recoveryTransaction.markCommitted()
            completePublishedState?()
        } catch {
            var rollbackFailures: [String] = []
            if publishedStateValidationStarted, let rollbackPublishedState {
                captureRollbackFailure(&rollbackFailures) {
                    try rollbackPublishedState()
                }
            }
            rollbackFailures.append(contentsOf: rollback(
                backupRoot: backupRoot,
                moves: backupMoves,
                publishedURLs: publishedURLs,
                createdDirectories: createdDirectories,
                preserveBackupFiles: true
            ))
            captureRollbackFailure(&rollbackFailures) {
                try invalidateModuleCache()
            }
            if rollbackFailures.isEmpty {
                do {
                    try recoveryTransaction.markRolledBack()
                    try recoveryJournal.removeIfPresent(backupRoot)
                    try recoveryTransaction.discard()
                } catch {
                    // Active journals retain backups; rolled-back journals are cleanup-only. Both
                    // states are idempotently recoverable on the next module-store initialization.
                }
            }
            try throwAfterRollback(original: error, rollbackFailures: rollbackFailures)
        }

        do {
            try recoveryJournal.removeIfPresent(backupRoot)
            try recoveryTransaction.discard()
        } catch {
            // The committed journal deliberately remains so startup can finish residue cleanup.
        }
        notifyModuleStoreChanged()
    }

    /** Publishes one content or activation file and records every inverse before mutation. */
    private func publishExactOverlayFile(
        relativePath: String,
        activation: Bool,
        stagingRootURL: URL,
        backupRoot: URL,
        recoveryTransaction: ModuleStoreRecoveryTransaction,
        backupMoves: inout [BackupMove],
        publishedURLs: inout [URL],
        createdDirectories: inout [URL]
    ) throws {
        let sourceURL = stagingRootURL.appendingPathComponent(relativePath)
        try validateStagedFile(
            sourceURL,
            relativePath: relativePath,
            stagingRoot: stagingRootURL
        )
        let destinationURL = canonicalRootURL.appendingPathComponent(relativePath)
        try resolver.validateCanonicalContainment(of: destinationURL, beneath: canonicalRootURL)
        let destinationDirectory = destinationURL.deletingLastPathComponent()
        if destinationDirectory.standardizedFileURL.path != canonicalRootURL.path {
            let createdDirectoryStart = createdDirectories.count
            try createLiveDirectory(destinationDirectory, tracking: &createdDirectories)
            for directory in createdDirectories.dropFirst(createdDirectoryStart) {
                try recoveryTransaction.recordCreatedDirectory(directory)
            }
        }

        let publicationSourceURL: URL
        if activation {
            let temporaryURL = destinationDirectory.appendingPathComponent(
                ".module-activation-\(UUID().uuidString).tmp"
            )
            try resolver.validateCanonicalContainment(of: temporaryURL, beneath: canonicalRootURL)
            try recoveryTransaction.recordPublishedURL(temporaryURL)
            publishedURLs.append(temporaryURL)
            try fileManager.copyItem(at: sourceURL, to: temporaryURL)
            publicationSourceURL = temporaryURL
        } else {
            publicationSourceURL = sourceURL
        }

        if let existing = existingURL(relativePath: relativePath) {
            let existingRelativePath = try rootRelativePath(for: existing)
            let backupURL = backupRoot.appendingPathComponent(existingRelativePath)
            try recoveryTransaction.recordBackupMove(
                originalURL: existing,
                backupURL: backupURL
            )
            try moveToBackup(existing, backupRoot: backupRoot, moves: &backupMoves)
            try recoveryTransaction.synchronizeBackupMove(
                originalURL: existing,
                backupURL: backupURL
            )
            try recoveryTransaction.markBackupMoveCompleted(originalURL: existing)
        }

        try recoveryTransaction.recordPublishedURL(destinationURL)
        publishedURLs.append(destinationURL)
        if activation {
            try fileManager.moveItem(at: publicationSourceURL, to: destinationURL)
        } else {
            try fileManager.copyItem(at: publicationSourceURL, to: destinationURL)
        }
    }
}
