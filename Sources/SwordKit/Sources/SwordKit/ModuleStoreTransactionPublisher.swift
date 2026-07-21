// ModuleStoreTransactionPublisher.swift - Transactional module-store publisher

import Foundation

/**
 Publishes and removes module payloads through the canonical process-wide transaction lease.

 The publisher is the only production API in SwordKit that moves staged SWORD/MyBible content into
 the live tree. It revalidates configs, payload ownership, conflicts, and symlink containment under
 the lease; backs up old and displaced targets; writes configs last; and holds the lease through
 rollback, cache invalidation, and the terminal notification.
 */
public final class ModuleStoreTransactionPublisher: @unchecked Sendable {
    struct InstalledConfigRecord {
        let layout: ModuleStoreInstalledLayout
        let actualConfigURL: URL
    }

    struct BackupMove {
        let originalURL: URL
        let backupURL: URL
    }

    let fileManager: FileManager
    let resolver: ModuleStoreInstalledLayoutResolver
    let coordinator: ModuleStoreMutationCoordinator
    let recoveryJournal: ModuleStoreRecoveryJournal

    /// Canonical SWORD root used by this publisher.
    public var canonicalRootURL: URL { resolver.canonicalRootURL }

    /**
     Creates a publisher sharing the process-wide coordinator for one root.

     - Parameters:
       - moduleRootURL: SWORD home containing live module files.
       - fileManager: Filesystem implementation used for all transaction operations.
     - Side effects: none; roots are created only inside an acquired transaction.
     */
    public init(moduleRootURL: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.resolver = ModuleStoreInstalledLayoutResolver(
            moduleRootURL: moduleRootURL,
            fileManager: fileManager
        )
        self.coordinator = ModuleStoreMutationCoordinator.shared(forModuleRoot: moduleRootURL)
        self.recoveryJournal = ModuleStoreRecoveryJournal(
            rootURL: moduleRootURL,
            fileManager: fileManager
        )
    }

    /**
     Recovers interrupted exact-path overlays before any module inventory is loaded.

     Active journals are rolled back; committed journals retain their published files and discard
     only backup residue. Recovery uses the same process-wide lease as every live module mutation.

     - Side effects: May restore displaced files, remove partially published files, invalidate the
       SWORD config cache, and post one module-store change notification.
     - Throws: Corrupt/unsafe journal data or filesystem failures that prevent complete recovery.
     */
    public func recoverInterruptedTransactions() throws {
        try coordinator.withExclusiveTransaction(kind: .recovery, prepare: { () }, commit: { _ in
            guard try recoveryJournal.recoverInterruptedTransactions() else { return }
            try invalidateModuleCache()
            notifyModuleStoreChanged()
        })
    }

    /** Delegates staged config/payload binding to the shared resolver. */
    public func validateStagedInstall(
        configurations: [ModuleStoreStagedConfiguration],
        payloadRelativePaths: [String]
    ) throws -> ModuleStoreStagedInstallPlan {
        try resolver.validateStagedInstall(
            configurations: configurations,
            payloadRelativePaths: payloadRelativePaths
        )
    }

    /** Resolves one raw catalog config before network or parent-directory work begins. */
    public func resolveCatalogLayout(
        moduleName: String,
        configurationContent: String
    ) throws -> ModuleStoreInstalledLayout {
        try resolver.resolve(
            ModuleStoreStagedConfiguration(
                relativePath: "mods.d/\(moduleName.lowercased()).conf",
                content: configurationContent
            )
        )
    }

    /**
     Publishes a staged SWORD install as one rollback-safe, non-cancellable transaction.

     - Parameters:
       - plan: Preflight plan built from archive/catalog config and payload paths.
       - stagingRootURL: Isolated root containing every planned file.
       - allowOverwrite: Whether current destinations may be displaced transactionally.
       - kind: Writer category for coordinator diagnostics.
       - onCommitStarted: Callback invoked after cancellation closes and before live-tree work.
     - Side effects: Replaces live payload/config files, removes obsolete same-initials payload,
       invalidates SWORD cache, and posts the module-change notification.
     - Throws: Cancellation before mutation, safety/ownership/conflict errors, filesystem errors, or
       a rollback error that includes both the original and restoration failures.
     */
    public func publishStagedInstall(
        _ plan: ModuleStoreStagedInstallPlan,
        from stagingRootURL: URL,
        allowOverwrite: Bool,
        kind: ModuleStoreMutationKind,
        onCommitStarted: (() -> Void)? = nil
    ) throws {
        try coordinator.withExclusiveTransaction(kind: kind, prepare: {
            let currentPlan = try revalidatedPlan(plan, from: stagingRootURL)
            let installed = try installedConfigRecords(requiredModuleNames: Set(currentPlan.moduleNames))
            try validateUniqueInstalledOwnership(incoming: currentPlan.layouts, installed: installed)

            var liveConflicts = Set(currentPlan.allRelativePaths.filter { relativePath in
                existingURL(relativePath: relativePath) != nil
            })
            liveConflicts.formUnion(
                try existingOwnedPayloadConflictPaths(for: currentPlan.layouts)
            )
            if !allowOverwrite, !liveConflicts.isEmpty {
                throw ModuleStoreMutationError.destinationFilesExist(liveConflicts.sorted())
            }
            return (plan: currentPlan, installed: installed)
        }, commit: { prepared in
            onCommitStarted?()
            try performSwordPublish(
                plan: prepared.plan,
                stagingRootURL: stagingRootURL,
                installed: prepared.installed
            )
        })
    }

    /**
     Publishes user-imported SWORD files as Android's exact-path overlay with transactional rollback.

     Unlike repository package replacement, Android's local/archive installer overwrites only file
     entries present in the selected archive and preserves other files under the same module data
     root. The coordinator still serializes mutation, validates module ownership, backs up every
     overwritten destination, writes configs last, and rolls the overlay back as one transaction.

     - Parameters:
       - plan: Validated config-to-payload binding for the imported archive.
       - stagingRootURL: Isolated root containing every planned archive file.
       - authorizedExistingPaths: Exact root-relative conflicts shown to and approved by the user.
       - kind: Writer category for coordinator diagnostics.
       - onCommitStarted: Callback after validation closes cancellation and before live mutation.
     - Side effects: Overlays staged files, invalidates the module cache, and posts one terminal
       module-store notification after successful commit.
     - Throws: Safety, ownership, filesystem, or rollback errors; newly appeared or unapproved live
       conflicts throw `ModuleStoreMutationError.destinationFilesExist` before mutation.
     - Important: Callers must independently bind `authorizedExistingPaths` to the archive digest
       presented during preflight. This transaction authorizes destinations, not archive identity.
     */
    public func publishStagedOverlay(
        _ plan: ModuleStoreStagedInstallPlan,
        from stagingRootURL: URL,
        authorizedExistingPaths: Set<String>,
        kind: ModuleStoreMutationKind,
        onCommitStarted: (() -> Void)? = nil
    ) throws {
        try coordinator.withExclusiveTransaction(kind: kind, prepare: {
            let currentPlan = try revalidatedPlan(plan, from: stagingRootURL)
            let installed = try installedConfigRecords(requiredModuleNames: Set(currentPlan.moduleNames))
            try validateUniqueInstalledOwnership(incoming: currentPlan.layouts, installed: installed)

            var liveConflicts: Set<String> = []
            var typeConflicts: [String] = []
            for relativePath in currentPlan.allRelativePaths {
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
            return currentPlan
        }, commit: { currentPlan in
            onCommitStarted?()
            try performSwordOverlay(plan: currentPlan, stagingRootURL: stagingRootURL)
        })
    }

    /** Rebuilds a staged plan from actual files while the exclusive lease is held. */
    private func revalidatedPlan(
        _ plan: ModuleStoreStagedInstallPlan,
        from stagingRootURL: URL
    ) throws -> ModuleStoreStagedInstallPlan {
        let canonicalStagingRoot = stagingRootURL.standardizedFileURL.resolvingSymlinksInPath()
        try validateIsolatedStagingRoot(canonicalStagingRoot)
        var configurations: [ModuleStoreStagedConfiguration] = []
        for relativePath in plan.configurationRelativePaths {
            let fileURL = canonicalStagingRoot.appendingPathComponent(relativePath)
            try validateStagedFile(fileURL, relativePath: relativePath, stagingRoot: canonicalStagingRoot)
            let data = try Data(contentsOf: fileURL)
            guard let content = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1) else {
                throw ModuleStoreMutationError.invalidConfiguration(relativePath)
            }
            configurations.append(ModuleStoreStagedConfiguration(
                relativePath: relativePath,
                content: content
            ))
        }
        for relativePath in plan.payloadRelativePaths {
            try validateStagedFile(
                canonicalStagingRoot.appendingPathComponent(relativePath),
                relativePath: relativePath,
                stagingRoot: canonicalStagingRoot
            )
        }
        let currentPlan = try resolver.validateStagedInstall(
            configurations: configurations,
            payloadRelativePaths: plan.payloadRelativePaths
        )
        guard currentPlan.configurationRelativePaths == plan.configurationRelativePaths,
              currentPlan.payloadRelativePaths == plan.payloadRelativePaths,
              currentPlan.moduleNames.map(resolver.filesystemCollisionKey)
                == plan.moduleNames.map(resolver.filesystemCollisionKey) else {
            throw ModuleStoreMutationError.invalidConfiguration("staged plan changed after preflight")
        }
        return currentPlan
    }

    /** Rejects a staging root that aliases or descends from the live module tree. */
    func validateIsolatedStagingRoot(_ stagingRoot: URL) throws {
        let livePath = canonicalRootURL.path
        let livePrefix = livePath.hasSuffix("/") ? livePath : livePath + "/"
        let stagingPath = stagingRoot.standardizedFileURL.resolvingSymlinksInPath().path
        guard stagingPath != livePath, !stagingPath.hasPrefix(livePrefix) else {
            throw ModuleStoreMutationError.canonicalPathEscape(stagingPath)
        }
    }

    /** Proves one staged source is a regular, non-symlink descendant of its isolated root. */
    func validateStagedFile(
        _ fileURL: URL,
        relativePath: String,
        stagingRoot: URL
    ) throws {
        let canonicalFile = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = stagingRoot.path.hasSuffix("/") ? stagingRoot.path : stagingRoot.path + "/"
        let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard canonicalFile.path.hasPrefix(rootPrefix),
              values?.isRegularFile == true,
              values?.isSymbolicLink != true else {
            throw ModuleStoreMutationError.stagedFileMissing(relativePath)
        }
    }

    /** Loads every installed config that can own SWORD payload and fails closed for targeted corruption. */
    func installedConfigRecords(
        requiredModuleNames: Set<String>
    ) throws -> [InstalledConfigRecord] {
        let requiredKeys = Set(requiredModuleNames.map(resolver.filesystemCollisionKey))
        let configsRoot = try resolver.canonicalConfigsRootURL()
        guard fileManager.fileExists(atPath: configsRoot.path) else { return [] }
        let files = try fileManager.contentsOfDirectory(
            at: configsRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "conf" }

        var records: [InstalledConfigRecord] = []
        var seenNames: Set<String> = []
        for fileURL in files {
            let fileName = fileURL.lastPathComponent
            let pathModuleName = (fileName as NSString).deletingPathExtension
            let pathKey = resolver.filesystemCollisionKey(pathModuleName)
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                if requiredKeys.contains(pathKey) {
                    throw ModuleStoreMutationError.invalidConfiguration("mods.d/\(fileName)")
                }
                continue
            }
            let data = try Data(contentsOf: fileURL)
            guard let content = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1) else {
                if requiredKeys.contains(pathKey) {
                    throw ModuleStoreMutationError.invalidConfiguration("mods.d/\(fileName)")
                }
                continue
            }
            let configuration = ModuleStoreStagedConfiguration(
                relativePath: "mods.d/\(fileName)",
                content: content
            )
            do {
                let layout = try resolver.resolve(configuration)
                let nameKey = resolver.filesystemCollisionKey(layout.moduleName)
                guard seenNames.insert(nameKey).inserted else {
                    throw ModuleStoreMutationError.duplicateModuleInitials(layout.moduleName)
                }
                records.append(InstalledConfigRecord(layout: layout, actualConfigURL: fileURL))
            } catch let error as ModuleStoreMutationError {
                let rawDataPath = rawConfigValue("datapath", content: content)
                let beginsInModules = rawDataPath.map { value in
                    var path = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if path.hasPrefix("./") { path.removeFirst(2) }
                    return path == "modules" || path.hasPrefix("modules/")
                } ?? false
                if requiredKeys.contains(pathKey) || beginsInModules {
                    throw error
                }
            }
        }
        return records
    }

    /** Rejects incoming and old targets that overlap payload owned by another installed config. */
    private func validateUniqueInstalledOwnership(
        incoming: [ModuleStoreInstalledLayout],
        installed: [InstalledConfigRecord]
    ) throws {
        for layout in incoming {
            for record in installed where
                record.layout.moduleName.caseInsensitiveCompare(layout.moduleName) != .orderedSame
                && resolver.layoutsOverlap(record.layout, layout) {
                throw ModuleStoreMutationError.installedOwnershipConflict(
                    moduleName: layout.moduleName,
                    owner: record.layout.moduleName
                )
            }
            if let old = installed.first(where: {
                $0.layout.moduleName.caseInsensitiveCompare(layout.moduleName) == .orderedSame
            }) {
                for record in installed where
                    record.layout.moduleName.caseInsensitiveCompare(old.layout.moduleName) != .orderedSame
                    && resolver.layoutsOverlap(record.layout, old.layout) {
                    throw ModuleStoreMutationError.installedOwnershipConflict(
                        moduleName: old.layout.moduleName,
                        owner: record.layout.moduleName
                    )
                }
            }
        }
    }

    /** Performs payload-first/config-last publication and restores every backup on failure. */
    private func performSwordPublish(
        plan: ModuleStoreStagedInstallPlan,
        stagingRootURL: URL,
        installed: [InstalledConfigRecord]
    ) throws {
        let modulesRoot = try resolver.canonicalModulesRootURL()
        let configsRoot = try resolver.canonicalConfigsRootURL()
        let backupRoot = canonicalRootURL.appendingPathComponent(
            ".module-transaction-\(UUID().uuidString).backup",
            isDirectory: true
        )
        var backupMoves: [BackupMove] = []
        var publishedURLs: [URL] = []
        var createdDirectories: [URL] = []

        do {
            try createLiveDirectory(modulesRoot, tracking: &createdDirectories)
            try createLiveDirectory(configsRoot, tracking: &createdDirectories)
            var targets: [URL] = []
            for incoming in plan.layouts {
                let currentIncoming = try resolver.revalidate(incoming)
                targets.append(contentsOf: try payloadTargets(for: currentIncoming))
                if let old = installed.first(where: {
                    $0.layout.moduleName.caseInsensitiveCompare(incoming.moduleName) == .orderedSame
                }) {
                    targets.append(contentsOf: try payloadTargets(for: try resolver.revalidate(old.layout)))
                    targets.append(old.actualConfigURL)
                } else if let configURL = existingURL(relativePath: incoming.configRelativePath) {
                    targets.append(configURL)
                }
            }
            for target in collapsedExistingTargets(targets) {
                try moveToBackup(target, backupRoot: backupRoot, moves: &backupMoves)
            }

            for relativePath in plan.payloadRelativePaths {
                let sourceURL = stagingRootURL.appendingPathComponent(relativePath)
                let destinationURL = canonicalRootURL.appendingPathComponent(relativePath)
                try resolver.validateCanonicalContainment(of: destinationURL, beneath: modulesRoot)
                try createLiveDirectory(
                    destinationURL.deletingLastPathComponent(),
                    tracking: &createdDirectories
                )
                if let existing = existingURL(relativePath: relativePath) {
                    try moveToBackup(existing, backupRoot: backupRoot, moves: &backupMoves)
                }
                publishedURLs.append(destinationURL)
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
            }

            for relativePath in plan.configurationRelativePaths {
                let sourceURL = stagingRootURL.appendingPathComponent(relativePath)
                let destinationURL = canonicalRootURL.appendingPathComponent(relativePath)
                try resolver.validateCanonicalContainment(of: destinationURL, beneath: configsRoot)
                let temporaryURL = configsRoot.appendingPathComponent(
                    ".module-config-\(UUID().uuidString).tmp"
                )
                try resolver.validateCanonicalContainment(of: temporaryURL, beneath: configsRoot)
                publishedURLs.append(temporaryURL)
                try fileManager.copyItem(at: sourceURL, to: temporaryURL)
                if let existing = existingURL(relativePath: relativePath) {
                    try moveToBackup(existing, backupRoot: backupRoot, moves: &backupMoves)
                }
                publishedURLs.append(destinationURL)
                try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            }

            for record in installed where plan.moduleNames.contains(where: {
                $0.caseInsensitiveCompare(record.layout.moduleName) == .orderedSame
            }) {
                try removeEmptyPayloadParents(for: record.layout)
            }
            try invalidateModuleCache()
            if fileManager.fileExists(atPath: backupRoot.path) {
                try fileManager.removeItem(at: backupRoot)
            }
            notifyModuleStoreChanged()
        } catch {
            let rollbackFailures = rollback(
                backupRoot: backupRoot,
                moves: backupMoves,
                publishedURLs: publishedURLs,
                createdDirectories: createdDirectories
            )
            try throwAfterRollback(original: error, rollbackFailures: rollbackFailures)
        }
    }

    /** Removes duplicate/descendant backup targets so a parent tree is moved exactly once. */
    func collapsedExistingTargets(_ targets: [URL]) -> [URL] {
        let existing = targets.filter { fileManager.fileExists(atPath: $0.path) }
        let sorted = existing.sorted {
            $0.standardizedFileURL.pathComponents.count < $1.standardizedFileURL.pathComponents.count
        }
        var result: [URL] = []
        for target in sorted {
            let key = resolver.filesystemCollisionKey(target.standardizedFileURL.path)
            let isCovered = result.contains { parent in
                let parentKey = resolver.filesystemCollisionKey(parent.standardizedFileURL.path)
                return key == parentKey || key.hasPrefix(parentKey + "/")
            }
            if !isCovered { result.append(target) }
        }
        return result
    }

    /**
     Returns existing non-empty payload targets owned by supplied driver-aware layouts.

     Inspection callers use this as a best-effort confirmation preview. Publication always invokes
     it again under the exclusive transaction lease before honoring a no-overwrite policy.
     */
    public func existingOwnedPayloadConflictPaths(
        for layouts: [ModuleStoreInstalledLayout]
    ) throws -> [String] {
        var conflicts: Set<String> = []
        for layout in layouts {
            for target in try payloadTargets(for: layout) {
                let values = try target.resourceValues(forKeys: [.isDirectoryKey])
                if values.isDirectory == true,
                   try fileManager.contentsOfDirectory(atPath: target.path).isEmpty {
                    continue
                }
                conflicts.insert(try rootRelativePath(for: target))
            }
        }
        return conflicts.sorted()
    }

    /** Moves one live target to a same-volume transaction backup and records its inverse. */
    func moveToBackup(
        _ originalURL: URL,
        backupRoot: URL,
        moves: inout [BackupMove]
    ) throws {
        guard fileManager.fileExists(atPath: originalURL.path) else { return }
        let originalKey = resolver.filesystemCollisionKey(originalURL.standardizedFileURL.path)
        guard !moves.contains(where: {
            resolver.filesystemCollisionKey($0.originalURL.standardizedFileURL.path) == originalKey
        }) else { return }
        let relativePath = try rootRelativePath(for: originalURL)
        let backupURL = backupRoot.appendingPathComponent(relativePath)
        try fileManager.createDirectory(
            at: backupURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.moveItem(at: originalURL, to: backupURL)
        moves.append(BackupMove(originalURL: originalURL, backupURL: backupURL))
    }

    /**
     Rolls back new files and restores displaced targets.

     - Parameters:
       - backupRoot: Same-volume directory containing displaced live files.
       - moves: Original-to-backup mappings in mutation order.
       - publishedURLs: New live paths to remove in reverse order.
       - createdDirectories: Directories created only for this transaction.
       - preserveBackupFiles: When `true`, restores by copy and retains backup storage so a durable
         recovery journal can repeat an interrupted rollback. Existing non-journal callers retain
         move-back behavior and remove an empty backup root.
     - Returns: Localized failures collected while attempting every inverse operation.
     - Side effects: Removes published paths, restores prior paths, prunes empty transaction-created
       directories, and optionally removes the backup root.
     */
    func rollback(
        backupRoot: URL,
        moves: [BackupMove],
        publishedURLs: [URL],
        createdDirectories: [URL] = [],
        preserveBackupFiles: Bool = false
    ) -> [String] {
        var failures: [String] = []
        for url in publishedURLs.reversed() where fileManager.fileExists(atPath: url.path) {
            captureRollbackFailure(&failures) { try fileManager.removeItem(at: url) }
        }
        for move in moves.reversed() where fileManager.fileExists(atPath: move.backupURL.path) {
            captureRollbackFailure(&failures) {
                try fileManager.createDirectory(
                    at: move.originalURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if fileManager.fileExists(atPath: move.originalURL.path) {
                    try fileManager.removeItem(at: move.originalURL)
                }
                if preserveBackupFiles {
                    try fileManager.copyItem(at: move.backupURL, to: move.originalURL)
                } else {
                    try fileManager.moveItem(at: move.backupURL, to: move.originalURL)
                }
            }
        }
        let uniqueCreatedDirectories = Dictionary(
            createdDirectories.map { (resolver.filesystemCollisionKey($0.path), $0) },
            uniquingKeysWith: { first, _ in first }
        ).values.sorted {
            $0.pathComponents.count > $1.pathComponents.count
        }
        for directory in uniqueCreatedDirectories where fileManager.fileExists(atPath: directory.path) {
            captureRollbackFailure(&failures) {
                let children = try fileManager.contentsOfDirectory(atPath: directory.path)
                if children.isEmpty {
                    try fileManager.removeItem(at: directory)
                }
            }
        }
        if !preserveBackupFiles,
           failures.isEmpty,
           fileManager.fileExists(atPath: backupRoot.path) {
            captureRollbackFailure(&failures) {
                try fileManager.removeItem(at: backupRoot)
            }
        }
        return failures
    }

    /** Creates a live-tree directory and records only absent descendants for rollback cleanup. */
    func createLiveDirectory(
        _ directoryURL: URL,
        tracking createdDirectories: inout [URL]
    ) throws {
        try resolver.validateCanonicalContainment(of: directoryURL, beneath: canonicalRootURL)
        var missingDirectories: [URL] = []
        var current = directoryURL.standardizedFileURL
        while current.path != canonicalRootURL.path,
              !fileManager.fileExists(atPath: current.path) {
            missingDirectories.append(current)
            current.deleteLastPathComponent()
        }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        createdDirectories.append(contentsOf: missingDirectories)
    }

    /** Records one rollback failure without hiding remaining restoration attempts. */
    func captureRollbackFailure(
        _ failures: inout [String],
        operation: () throws -> Void
    ) {
        do {
            try operation()
        } catch {
            failures.append(error.localizedDescription)
        }
    }

    /** Rethrows the original error only when rollback fully succeeded. */
    func throwAfterRollback(
        original: Error,
        rollbackFailures: [String]
    ) throws -> Never {
        guard !rollbackFailures.isEmpty else { throw original }
        throw ModuleStoreMutationError.rollbackFailed(
            original: original.localizedDescription,
            failures: rollbackFailures
        )
    }

    /** Invalidates SWORD's cache while rollback storage is still available. */
    func invalidateModuleCache() throws {
        let cacheURL = try resolver.canonicalConfigsRootURL()
            .appendingPathComponent("modules-conf.cache")
        if fileManager.fileExists(atPath: cacheURL.path) {
            try fileManager.removeItem(at: cacheURL)
        }
    }

    /** Posts the terminal module-tree notification as the final transaction operation. */
    func notifyModuleStoreChanged() {
        SwordModuleStore.notifyModulesDidChange()
    }

    /** Finds an existing path with case-insensitive component matching under the canonical root. */
    func existingURL(relativePath: String) -> URL? {
        var current = canonicalRootURL
        for rawComponent in relativePath.split(separator: "/") {
            let component = String(rawComponent)
            let key = resolver.filesystemCollisionKey(component)
            guard let children = try? fileManager.contentsOfDirectory(
                at: current,
                includingPropertiesForKeys: nil
            ), let match = children.first(where: {
                resolver.filesystemCollisionKey($0.lastPathComponent) == key
            }) else {
                return nil
            }
            // Enumeration may rewrite a macOS firmlink root (`/var` to `/private/var`). Retain
            // only the actual component spelling so later root-relative derivation uses one alias.
            current = current.appendingPathComponent(match.lastPathComponent)
        }
        return current
    }

    /** Converts a contained live URL into a safe canonical-root-relative backup path. */
    func rootRelativePath(for url: URL) throws -> String {
        let resolvedRoot = canonicalRootURL.standardizedFileURL
            .resolvingSymlinksInPath().standardizedFileURL
        let resolvedURL = url.standardizedFileURL
            .resolvingSymlinksInPath().standardizedFileURL
        try resolver.validateCanonicalContainment(of: resolvedURL, beneath: resolvedRoot)
        let rootPrefix = resolvedRoot.path.hasSuffix("/")
            ? resolvedRoot.path
            : resolvedRoot.path + "/"
        let path = resolvedURL.path
        guard path.hasPrefix(rootPrefix) else {
            throw ModuleStoreMutationError.canonicalPathEscape(path)
        }
        return String(path.dropFirst(rootPrefix.count))
    }

    /** Reads one case-insensitive key directly from config content for fail-closed legacy handling. */
    private func rawConfigValue(_ key: String, content: String) -> String? {
        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let equals = line.firstIndex(of: "=") else { continue }
            let candidate = line[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.caseInsensitiveCompare(key) == .orderedSame {
                return line[line.index(after: equals)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

}
