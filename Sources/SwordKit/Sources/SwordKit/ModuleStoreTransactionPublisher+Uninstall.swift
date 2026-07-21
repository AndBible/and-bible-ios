// ModuleStoreTransactionPublisher+Uninstall.swift - Transactional module removal

import Foundation

/** Immutable under-lease uninstall plan produced before cancellation closes. */
private enum PreparedModuleStoreUninstall {
    case myBible(URL)
    case sword(ModuleStoreTransactionPublisher.InstalledConfigRecord)
}

extension ModuleStoreTransactionPublisher {
    /**
     Transactionally uninstalls a MyBible sidecar module or a validated SWORD module.

     - Parameter moduleName: Installed module initials.
     - Side effects: Moves config/payload to rollback storage, invalidates cache, posts notification,
       then deletes rollback storage on success.
     - Throws: `moduleNotFound`, unsafe legacy layout, ownership conflict, filesystem failure, or
       rollback failure. No raw `DataPath` append or silent deletion is performed.
     */
    public func uninstall(moduleName: String) throws {
        let safeName = try resolver.safeModuleName(moduleName)
        try coordinator.withExclusiveTransaction(kind: .uninstall, prepare: {
            if let moduleURL = try myBibleModuleURLIfPresent(moduleName: safeName) {
                return PreparedModuleStoreUninstall.myBible(moduleURL)
            }

            let installed = try installedConfigRecords(requiredModuleNames: [safeName])
            guard let target = installed.first(where: {
                $0.layout.moduleName.caseInsensitiveCompare(safeName) == .orderedSame
            }) else {
                throw ModuleStoreMutationError.moduleNotFound(safeName)
            }
            for other in installed where
                other.layout.moduleName.caseInsensitiveCompare(target.layout.moduleName) != .orderedSame
                && resolver.layoutsOverlap(other.layout, target.layout) {
                throw ModuleStoreMutationError.installedOwnershipConflict(
                    moduleName: target.layout.moduleName,
                    owner: other.layout.moduleName
                )
            }
            return PreparedModuleStoreUninstall.sword(target)
        }, commit: { target in
            switch target {
            case .myBible(let moduleURL):
                try performMyBibleUninstall(moduleURL: moduleURL)
            case .sword(let record):
                try performSwordUninstall(target: record)
            }
        })
    }

    /** Removes one under-lease, prevalidated SWORD layout through rollback storage. */
    private func performSwordUninstall(target: InstalledConfigRecord) throws {
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

    /**
     Resolves current live payload targets for a driver-aware layout.

     - Parameter layout: Revalidated installed layout.
     - Returns: Existing directory target or exact prefix-driver files.
     - Side effects: Reads live directory entries and canonical path metadata.
     - Throws: Filesystem or canonical-containment errors.
     */
    func payloadTargets(for layout: ModuleStoreInstalledLayout) throws -> [URL] {
        guard fileManager.fileExists(atPath: layout.dataDirectoryURL.path) else { return [] }
        let directoryValues = try layout.dataDirectoryURL.resourceValues(forKeys: [.isDirectoryKey])
        guard directoryValues.isDirectory == true else {
            throw ModuleStoreMutationError.invalidConfiguration(layout.configRelativePath)
        }

        switch layout.payloadShape {
        case .directory:
            return [layout.dataDirectoryURL]
        case .filenamePrefix(let prefix):
            let prefixKey = resolver.filesystemCollisionKey(prefix)
            let children = try fileManager.contentsOfDirectory(
                at: layout.dataDirectoryURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
            var targets: [URL] = []
            for child in children where resolver.filesystemCollisionKey(child.lastPathComponent)
                .hasPrefix(prefixKey) {
                let values = try child.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                try resolver.validateCanonicalContainment(
                    of: child,
                    beneath: try resolver.canonicalModulesRootURL()
                )
                targets.append(child)
            }
            return targets
        }
    }

    /**
     Removes empty ancestors left by replacement or uninstall without crossing `modules/`.

     - Parameter layout: Layout whose payload parent may now be empty.
     - Side effects: Deletes empty directories only.
     - Throws: Directory enumeration or removal failures.
     */
    func removeEmptyPayloadParents(for layout: ModuleStoreInstalledLayout) throws {
        let modulesRoot = try resolver.canonicalModulesRootURL()
        var current = layout.dataDirectoryURL
        while current.path != modulesRoot.path {
            guard fileManager.fileExists(atPath: current.path) else {
                current.deleteLastPathComponent()
                continue
            }
            let children = try fileManager.contentsOfDirectory(atPath: current.path)
            guard children.isEmpty else { return }
            try fileManager.removeItem(at: current)
            current.deleteLastPathComponent()
        }
    }
}
