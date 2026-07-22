// ModuleStoreTransactionPublisher+MyBible.swift - Transactional MyBible publication

import Foundation

extension ModuleStoreTransactionPublisher {
    /**
     Publishes one staged MyBible directory under the same canonical-root lease as SWORD writers.

     - Parameters:
       - stagingDirectory: Isolated directory containing payload and `module.json`.
       - moduleName: Safe MyBible initials used as the final directory name.
       - onCommitStarted: Callback invoked after cancellation closes and before live-tree work.
     - Side effects: Replaces the live MyBible directory transactionally and posts one notification.
     - Throws: Cancellation before mutation, unsafe paths, missing staged metadata/payload, or
       filesystem/rollback errors.
     */
    public func publishStagedMyBibleInstall(
        from stagingDirectory: URL,
        moduleName: String,
        onCommitStarted: (() -> Void)? = nil
    ) throws {
        let safeName = try resolver.safeModuleName(moduleName)
        try coordinator.withExclusiveTransaction(kind: .remoteMyBible, prepare: {
            let stagingCanonical = stagingDirectory.standardizedFileURL.resolvingSymlinksInPath()
            try validateIsolatedStagingRoot(stagingCanonical)
            guard fileManager.fileExists(
                atPath: stagingCanonical.appendingPathComponent("module.json").path
            ) else {
                throw ModuleStoreMutationError.stagedFileMissing("module.json")
            }
            let children = try fileManager.contentsOfDirectory(
                at: stagingCanonical,
                includingPropertiesForKeys: nil
            )
            guard children.contains(where: { $0.lastPathComponent != "module.json" }) else {
                throw ModuleStoreMutationError.missingPayload(safeName)
            }

            let myBibleRoot = canonicalRootURL.appendingPathComponent("mybible", isDirectory: true)
            try resolver.validateCanonicalContainment(of: myBibleRoot, beneath: canonicalRootURL)
            let finalURL = myBibleRoot.appendingPathComponent(safeName, isDirectory: true)
            try resolver.validateCanonicalContainment(of: finalURL, beneath: myBibleRoot)
            return (
                stagingCanonical: stagingCanonical,
                myBibleRoot: myBibleRoot,
                finalURL: finalURL
            )
        }, commit: { prepared in
            onCommitStarted?()
            let backupRoot = canonicalRootURL.appendingPathComponent(
                ".module-transaction-\(UUID().uuidString).backup",
                isDirectory: true
            )
            var backupMove: BackupMove?
            var createdDirectories: [URL] = []
            do {
                try createLiveDirectory(prepared.myBibleRoot, tracking: &createdDirectories)
                if fileManager.fileExists(atPath: prepared.finalURL.path) {
                    let backupURL = backupRoot.appendingPathComponent(
                        "mybible/\(safeName)",
                        isDirectory: true
                    )
                    try fileManager.createDirectory(
                        at: backupURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try fileManager.moveItem(at: prepared.finalURL, to: backupURL)
                    backupMove = BackupMove(originalURL: prepared.finalURL, backupURL: backupURL)
                }
                try fileManager.copyItem(at: prepared.stagingCanonical, to: prepared.finalURL)
                if fileManager.fileExists(atPath: backupRoot.path) {
                    try fileManager.removeItem(at: backupRoot)
                }
                notifyModuleStoreChanged()
            } catch {
                let rollbackFailures = rollback(
                    backupRoot: backupRoot,
                    moves: backupMove.map { [$0] } ?? [],
                    publishedURLs: [prepared.finalURL],
                    createdDirectories: createdDirectories
                )
                try throwAfterRollback(original: error, rollbackFailures: rollbackFailures)
            }
        })
    }

    /**
     Resolves a valid installed MyBible sidecar without mutating the live tree.

     - Parameter moduleName: Validated MyBible initials.
     - Returns: The contained module directory, or `nil` when no sidecar metadata exists.
     - Side effects: Reads path metadata under the transaction lease.
     - Throws: Canonical-containment, malformed-sidecar, or filesystem errors.
     */
    func myBibleModuleURLIfPresent(moduleName: String) throws -> URL? {
        let myBibleRoot = canonicalRootURL.appendingPathComponent("mybible", isDirectory: true)
        try resolver.validateCanonicalContainment(of: myBibleRoot, beneath: canonicalRootURL)
        let moduleURL = myBibleRoot.appendingPathComponent(moduleName, isDirectory: true)
        try resolver.validateCanonicalContainment(of: moduleURL, beneath: myBibleRoot)
        guard fileManager.fileExists(atPath: moduleURL.path) else { return nil }
        let moduleValues = try moduleURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard moduleValues.isDirectory == true, moduleValues.isSymbolicLink != true else {
            throw ModuleStoreMutationError.invalidConfiguration("mybible/\(moduleName)")
        }
        let metadataURL = moduleURL.appendingPathComponent("module.json")
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            throw ModuleStoreMutationError.invalidConfiguration("mybible/\(moduleName)/module.json")
        }
        let metadataValues = try metadataURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard metadataValues.isRegularFile == true,
              metadataValues.isSymbolicLink != true else {
            throw ModuleStoreMutationError.invalidConfiguration("mybible/\(moduleName)/module.json")
        }
        return moduleURL
    }

    /** Removes one prevalidated MyBible directory through rollback storage. */
    func performMyBibleUninstall(moduleURL: URL) throws {
        let backupRoot = canonicalRootURL.appendingPathComponent(
            ".module-transaction-\(UUID().uuidString).backup",
            isDirectory: true
        )
        var moves: [BackupMove] = []
        do {
            try moveToBackup(moduleURL, backupRoot: backupRoot, moves: &moves)
            try fileManager.removeItem(at: backupRoot)
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
