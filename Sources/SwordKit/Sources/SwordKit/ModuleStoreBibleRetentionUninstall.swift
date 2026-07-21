// ModuleStoreBibleRetentionUninstall.swift - Last-Bible-safe transactional removal

import Foundation

/**
 Reports fail-closed policy outcomes from a Bible-retaining uninstall preparation.

 Values are raised while the canonical module-root mutation lease is held and before any live-tree
 move begins. The enum itself has no side effects; callers map it to their public service errors.
 */
enum ModuleStoreBibleRetentionError: Error, Equatable {
    /// Installed inventory could not be loaded while the module-store lease was held.
    case inventoryUnavailable

    /// Removing the named module would leave no installed Bible.
    case lastInstalledBible(String)
}

/**
 Captures one installed target after ownership and Bible-retention checks pass under the lease.

 The value is consumed only by the same transaction's non-cancellable commit closure. Creating it
 performs no mutation and cannot fail after its associated URLs/config record have been validated.
 */
private enum PreparedBibleRetainingUninstall {
    /// Android-compatible MyBible sidecar directory.
    case myBible(URL)

    /// Validated SWORD config and payload layout.
    case sword(ModuleStoreTransactionPublisher.InstalledConfigRecord)
}

extension ModuleStoreTransactionPublisher {
    /**
     Transactionally uninstalls a module while retaining at least one installed Bible.

     The inventory check and target preparation run inside the canonical-root coordinator lease.
     A second concurrent removal therefore observes the first removal's committed inventory and
     cannot independently approve deletion of the remaining Bible.

     - Parameters:
       - moduleName: Installed module initials.
       - inventoryProvider: Fresh installed inventory loader invoked under the mutation lease.
     - Side effects: Reads installed inventory and, when allowed, moves config/payload to rollback
       storage, invalidates SWORD's cache, posts one terminal notification, and removes rollback
       storage after success.
     - Throws: `ModuleStoreBibleRetentionError` when inventory is unavailable or removal targets the
       only installed Bible; otherwise the same lookup, layout, ownership, filesystem, and rollback
       failures as ordinary transactional uninstall.
     - Important: `inventoryProvider` runs after the process-wide coordinator lease is acquired.
       It must return a fresh snapshot and must not initiate another module-store transaction.
     */
    func uninstallPreservingAtLeastOneBible(
        moduleName: String,
        inventoryProvider: () -> [ModuleInfo]?
    ) throws {
        let safeName = try resolver.safeModuleName(moduleName)
        try coordinator.withExclusiveTransaction(kind: .uninstall, prepare: {
            let target: PreparedBibleRetainingUninstall
            if let moduleURL = try myBibleModuleURLIfPresent(moduleName: safeName) {
                target = .myBible(moduleURL)
            } else {
                let installed = try installedConfigRecords(requiredModuleNames: [safeName])
                guard let record = installed.first(where: {
                    $0.layout.moduleName.caseInsensitiveCompare(safeName) == .orderedSame
                }) else {
                    throw ModuleStoreMutationError.moduleNotFound(safeName)
                }
                for other in installed where
                    other.layout.moduleName.caseInsensitiveCompare(record.layout.moduleName) != .orderedSame
                    && resolver.layoutsOverlap(other.layout, record.layout) {
                    throw ModuleStoreMutationError.installedOwnershipConflict(
                        moduleName: record.layout.moduleName,
                        owner: other.layout.moduleName
                    )
                }
                target = .sword(record)
            }

            guard let inventory = inventoryProvider() else {
                throw ModuleStoreBibleRetentionError.inventoryUnavailable
            }
            if inventory.first(where: {
                $0.name.caseInsensitiveCompare(safeName) == .orderedSame
            })?.category == .bible,
            inventory.lazy.filter({ $0.category == .bible }).count <= 1 {
                throw ModuleStoreBibleRetentionError.lastInstalledBible(safeName)
            }
            return target
        }, commit: { target in
            switch target {
            case .myBible(let moduleURL):
                try performMyBibleUninstall(moduleURL: moduleURL)
            case .sword(let record):
                try performBibleRetainingSwordUninstall(target: record)
            }
        })
    }

    /**
     Removes one protected SWORD target through the publisher's rollback machinery.

     - Parameter target: Under-lease installed config record whose Bible-retention policy passed.
     - Side effects: Moves owned payload and config to backup, invalidates cache, posts the mutation
       notification, then removes backup storage.
     - Throws: Revalidation, filesystem, cache-invalidation, or rollback failures.
     */
    private func performBibleRetainingSwordUninstall(
        target: InstalledConfigRecord
    ) throws {
        let backupRoot = canonicalRootURL.appendingPathComponent(
            ".module-transaction-\(UUID().uuidString).backup",
            isDirectory: true
        )
        var moves: [BackupMove] = []
        do {
            let targets = try payloadTargets(for: try resolver.revalidate(target.layout))
                + [target.actualConfigURL]
            for originalURL in collapsedExistingTargets(targets) {
                try moveToBackup(originalURL, backupRoot: backupRoot, moves: &moves)
            }
            try removeEmptyPayloadParents(for: target.layout)
            try invalidateModuleCache()
            if fileManager.fileExists(atPath: backupRoot.path) {
                try fileManager.removeItem(at: backupRoot)
            }
            notifyModuleStoreChanged()
        } catch {
            let rollbackFailures = rollback(
                backupRoot: backupRoot,
                moves: moves,
                publishedURLs: []
            )
            try throwAfterRollback(original: error, rollbackFailures: rollbackFailures)
        }
    }
}
