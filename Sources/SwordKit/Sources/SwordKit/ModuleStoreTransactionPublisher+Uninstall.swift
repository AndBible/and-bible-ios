// ModuleStoreTransactionPublisher+Uninstall.swift - Transactional module removal

import Foundation

/** Immutable under-lease uninstall plan produced before cancellation closes. */
private enum PreparedModuleStoreUninstall {
    case myBible(URL)
    case sword(ModuleStoreTransactionPublisher.InstalledConfigRecord)
}

/** Exact installed add-on owner captured and revalidated under the mutation lease. */
private enum PreparedInstalledAddonUninstall {
    /// One config-backed SWORD add-on and its validated adjusted payload location.
    case sword(configURL: URL, locationURL: URL?)

    /// One generated `CsvPromptBook` file below the canonical `prompts` directory.
    case standalonePromptCSV(URL)
}

extension ModuleStoreTransactionPublisher {
    /**
     Transactionally removes the exact owner represented by one admitted add-on row.

     - Parameter target: Opaque config or standalone-CSV identity captured by `SwordManager` from
       the installed registry generation shown to the user.
     - Side effects: Acquires the canonical-root lease, revalidates the exact owner, moves its files
       to rollback storage, invalidates the SWORD cache, and posts one terminal notification.
     - Throws: Stale/mismatched identity, unsafe path, shared payload ownership, filesystem, cache,
       or rollback failures. The function never falls back to a same-initials sibling.
     */
    func uninstallInstalledAddon(_ target: SwordInstalledAddonRemovalTarget) throws {
        try coordinator.withExclusiveTransaction(kind: .uninstall, prepare: {
            guard let currentManager = SwordManager(modulePath: canonicalRootURL.path),
                  currentManager.admittedAddonModules().contains(where: {
                      $0.removalTarget == target
                  }) else {
                throw ModuleStoreMutationError.moduleNotFound(target.moduleName)
            }

            switch target.storage {
            case .swordConfig(
                let relativePath,
                let moduleName,
                let fullName,
                let abbreviation,
                let driver,
                let dataPath,
                let locationRelativePath
            ):
                let configs = SwordModuleConfig.readAll(modulePath: canonicalRootURL.path)
                guard let config = configs.first(where: {
                    guard let sourceURL = $0.sourceURL else { return false }
                    return SwordJavaStringIdentity.equals(
                        Self.relativePath(of: sourceURL, under: canonicalRootURL),
                        relativePath
                    )
                }),
                let configURL = config.sourceURL,
                config.moduleInfo.category == .addon,
                SwordJavaStringIdentity.equals(config.name, moduleName),
                SwordJavaStringIdentity.equals(config.description, fullName),
                SwordJavaStringIdentity.equals(config.modDrv, driver),
                SwordJavaStringIdentity.equals(config.dataPath, dataPath),
                SwordJavaStringIdentity.equals(
                    Self.installedAbbreviation(config: config),
                    abbreviation
                ) else {
                    throw ModuleStoreMutationError.moduleNotFound(moduleName)
                }

                let adjustedLocation = SwordManager.adjustedModuleLocation(
                    for: config,
                    modulePath: canonicalRootURL.path
                )
                guard let adjustedLocation,
                      Self.locationMatches(
                        adjustedLocation,
                        expectedRelativePath: locationRelativePath,
                        rootURL: canonicalRootURL
                      ) else {
                    throw ModuleStoreMutationError.moduleNotFound(moduleName)
                }
                let locationURL = adjustedLocation.url
                let canonicalRoot = canonicalRootURL.standardizedFileURL.resolvingSymlinksInPath()
                if let locationURL,
                   SwordJavaStringIdentity.equals(locationURL.path, canonicalRoot.path) {
                    throw ModuleStoreMutationError.invalidConfiguration(relativePath)
                }
                if let locationURL,
                   isProtectedInstalledFamilyRoot(locationURL) {
                    throw ModuleStoreMutationError.installedOwnershipConflict(
                        moduleName: moduleName,
                        owner: locationURL.lastPathComponent
                    )
                }

                for other in configs {
                    guard let otherURL = other.sourceURL,
                          !SwordJavaStringIdentity.equals(
                            otherURL.standardizedFileURL.path,
                            configURL.standardizedFileURL.path
                          ),
                          let otherLocation = SwordManager.adjustedModuleLocation(
                            for: other,
                            modulePath: canonicalRootURL.path
                          ).flatMap(\.url),
                          let locationURL,
                          Self.pathsOverlap(locationURL, otherLocation) else {
                        continue
                    }
                    throw ModuleStoreMutationError.installedOwnershipConflict(
                        moduleName: moduleName,
                        owner: other.name
                    )
                }
                return PreparedInstalledAddonUninstall.sword(
                    configURL: configURL,
                    locationURL: locationURL
                )

            case .standalonePromptCSV(let fileName, let moduleName):
                return .standalonePromptCSV(
                    try preparedStandalonePromptCSV(
                        fileName: fileName,
                        moduleName: moduleName
                    )
                )
            }
        }, commit: { (prepared: PreparedInstalledAddonUninstall) in
            switch prepared {
            case .sword(let configURL, let locationURL):
                try performInstalledAddonConfigUninstall(
                    configURL: configURL,
                    locationURL: locationURL
                )
            case .standalonePromptCSV(let fileURL):
                try performStandalonePromptCSVUninstall(fileURL: fileURL)
            }
        })
    }

    /**
     Removes one exact config-backed add-on through rollback storage.

     - Parameters:
       - configURL: Revalidated direct-root config that produced the selected installed Book.
       - locationURL: Revalidated JSword-adjusted payload directory, or nil for no-location books.
     - Side effects: Moves the adjusted location and config to rollback storage, invalidates cache,
       posts one terminal notification, and removes backup storage after success.
     - Throws: Filesystem, cache-invalidation, or rollback failures.
     */
    private func performInstalledAddonConfigUninstall(
        configURL: URL,
        locationURL: URL?
    ) throws {
        let backupRoot = canonicalRootURL.appendingPathComponent(
            ".module-transaction-\(UUID().uuidString).backup",
            isDirectory: true
        )
        var moves: [BackupMove] = []
        do {
            let targets = (locationURL.map { [$0] } ?? []) + [configURL]
            for originalURL in collapsedExistingTargets(targets) {
                try moveToBackup(originalURL, backupRoot: backupRoot, moves: &moves)
            }
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
     Produces one exact path relative to a canonical module root.

     - Parameters:
       - url: Installed config or adjusted location URL.
       - rootURL: Canonical SWORD root that must contain `url`.
     - Returns: Exact relative path, an empty string for the root itself, or an impossible sentinel
       for an escaped path so caller equality fails closed.
     - Side effects: Resolves symlinks and standardizes paths without mutation.
     - Failure modes: None exposed; escaped paths return the sentinel rather than throwing.
     */
    private static func relativePath(of url: URL, under rootURL: URL) -> String {
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let child = url.standardizedFileURL.resolvingSymlinksInPath()
        if SwordJavaStringIdentity.equals(root.path, child.path) { return "" }
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard child.path.hasPrefix(rootPrefix) else { return "\0escaped" }
        return String(child.path.dropFirst(rootPrefix.count))
    }

    /**
     Checks a fresh adjusted location against the opaque row identity.

     - Parameters:
       - location: Fresh JSword adjusted-location result for the selected config.
       - expectedRelativePath: Relative location captured with the installed row, or nil when the
         row had no adjusted location.
       - rootURL: Canonical SWORD root used for relative-path comparison.
     - Returns: `true` only when both generations have the same no-location/location state and exact
       UTF-16 relative path.
     - Side effects: Resolves paths without mutation.
     - Failure modes: None; escaped locations compare false.
     */
    private static func locationMatches(
        _ location: SwordManager.AdjustedModuleLocation,
        expectedRelativePath: String?,
        rootURL: URL
    ) -> Bool {
        switch (location, expectedRelativePath) {
        case (.noLocation, nil):
            return true
        case (.location(let url), .some(let expected)):
            return SwordJavaStringIdentity.equals(
                relativePath(of: url, under: rootURL),
                expected
            )
        case (.noLocation, .some), (.location, nil):
            return false
        }
    }

    /**
     Reports whether two adjusted payload directories overlap.

     - Parameters:
       - lhs: First standardized installed payload directory.
       - rhs: Second standardized installed payload directory.
     - Returns: `true` when either directory equals or contains the other.
     - Side effects: Resolves symlinks without mutation.
     - Failure modes: None; callers have already bounded both locations to the canonical root.
     */
    private static func pathsOverlap(_ lhs: URL, _ rhs: URL) -> Bool {
        let left = lhs.standardizedFileURL.resolvingSymlinksInPath().path
        let right = rhs.standardizedFileURL.resolvingSymlinksInPath().path
        if SwordJavaStringIdentity.equals(left, right) { return true }
        let leftPrefix = left.hasSuffix("/") ? left : left + "/"
        let rightPrefix = right.hasSuffix("/") ? right : right + "/"
        return left.hasPrefix(rightPrefix) || right.hasPrefix(leftPrefix)
    }

    /**
     Reports whether an adjusted location is a shared top-level installed-family root.

     Config-backed add-ons may own dedicated descendants such as `addons/foo`, but cannot remove
     the roots used by config files, normal SWORD payloads, Android raw-module families, generated
     resources, or transaction recovery. Those roots can contain owners that do not participate in
     native config-location overlap checks, including generated standalone prompt CSV books.

     - Parameter locationURL: Fresh JSword-adjusted location bounded by the canonical module root.
     - Returns: `true` only when the location is exactly one protected top-level family directory.
     - Side effects: Resolves paths and applies the resolver's deterministic filesystem collision
       key without mutation.
     - Failure modes: Escaped, root, and nested paths return false here and are handled by the
       surrounding containment/root/overlap gates.
     */
    private func isProtectedInstalledFamilyRoot(_ locationURL: URL) -> Bool {
        let relativePath = Self.relativePath(of: locationURL, under: canonicalRootURL)
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 1, let component = components.first, !component.isEmpty else {
            return false
        }
        let key = resolver.filesystemCollisionKey(String(component))
        let protectedKeys = [
            "mods.d", "modules", "mybible", "mysword", "esword", "epub", "ttf",
            "background", "prompts", ".module-recovery",
        ].map(resolver.filesystemCollisionKey)
        return protectedKeys.contains(key) || key.hasPrefix(".module-transaction-")
    }

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
            let hasRegisteredConfigIdentity = SwordModuleConfig.readAll(
                modulePath: canonicalRootURL.path
            ).contains {
                SwordJavaStringIdentity.equalsIgnoreCase($0.name, safeName)
            }
            if hasRegisteredConfigIdentity {
                let installed = try installedConfigRecords(requiredModuleNames: [safeName])
                if let target = installed.first(where: {
                    $0.layout.moduleName.caseInsensitiveCompare(safeName) == .orderedSame
                }) {
                    for other in installed where
                        other.layout.moduleName.caseInsensitiveCompare(target.layout.moduleName)
                            != .orderedSame
                        && resolver.layoutsOverlap(other.layout, target.layout) {
                        throw ModuleStoreMutationError.installedOwnershipConflict(
                            moduleName: target.layout.moduleName,
                            owner: other.layout.moduleName
                        )
                    }
                    return PreparedModuleStoreUninstall.sword(target)
                }
            }

            if let moduleURL = try myBibleModuleURLIfPresent(moduleName: safeName) {
                return PreparedModuleStoreUninstall.myBible(moduleURL)
            }
            throw ModuleStoreMutationError.moduleNotFound(safeName)
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
     Resolves and validates one generated `CsvPromptBook` deletion target under the mutation lease.

     - Parameters:
       - fileName: Exact direct child name captured from the installed prompts enumeration.
       - moduleName: Exact generated `Prompts_<stem>` initials captured with the row.
     - Returns: Current regular, non-symlink CSV URL bounded by the canonical prompts directory.
     - Side effects: Resolves symlinks and reads filesystem metadata without mutation.
     - Throws: Unsafe/stale path, wrong generated initials, or missing/nonregular file failures.
     */
    private func preparedStandalonePromptCSV(
        fileName: String,
        moduleName: String
    ) throws -> URL {
        guard !fileName.isEmpty,
              !fileName.contains("/"),
              (fileName as NSString).lastPathComponent == fileName,
              SwordJavaStringIdentity.equalsIgnoreCase(
                (fileName as NSString).pathExtension,
                "csv"
              ) else {
            throw ModuleStoreMutationError.unsafeArchivePath(fileName)
        }
        let expectedModuleName = "Prompts_\((fileName as NSString).deletingPathExtension)"
        guard SwordJavaStringIdentity.equals(expectedModuleName, moduleName) else {
            throw ModuleStoreMutationError.moduleNotFound(moduleName)
        }

        let rootURL = canonicalRootURL.standardizedFileURL.resolvingSymlinksInPath()
        let promptsURL = canonicalRootURL
            .appendingPathComponent("prompts", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard promptsURL.path.hasPrefix(rootPrefix) else {
            throw ModuleStoreMutationError.canonicalPathEscape(promptsURL.path)
        }
        let fileURL = promptsURL
            .appendingPathComponent(fileName, isDirectory: false)
            .standardizedFileURL
        let canonicalFileURL = fileURL.resolvingSymlinksInPath()
        let promptsPrefix = promptsURL.path.hasSuffix("/") ? promptsURL.path : promptsURL.path + "/"
        let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard canonicalFileURL.path.hasPrefix(promptsPrefix),
              values?.isRegularFile == true,
              values?.isSymbolicLink != true else {
            throw ModuleStoreMutationError.moduleNotFound(moduleName)
        }
        return fileURL
    }

    /**
     Removes one under-lease generated prompt CSV through the publisher rollback machinery.

     - Parameter fileURL: Revalidated regular direct child of the canonical prompts directory.
     - Side effects: Moves the CSV to rollback storage, invalidates the SWORD cache, posts one
       terminal notification, and removes rollback storage after success.
     - Throws: Filesystem, cache-invalidation, or rollback failures.
     */
    private func performStandalonePromptCSVUninstall(fileURL: URL) throws {
        let backupRoot = canonicalRootURL.appendingPathComponent(
            ".module-transaction-\(UUID().uuidString).backup",
            isDirectory: true
        )
        var moves: [BackupMove] = []
        do {
            try moveToBackup(fileURL, backupRoot: backupRoot, moves: &moves)
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
     Returns the exact JSword abbreviation for one installed config.

     - Parameter config: Parsed installed SWORD configuration.
     - Returns: Java-trimmed first `Abbreviation`, or exact initials when absent/empty.
     - Side effects: None.
     - Failure modes: None; initials are always present on a parsed config.
     */
    private static func installedAbbreviation(config: SwordModuleConfig) -> String {
        let abbreviation = config.values["Abbreviation"]?.first
            .map(SwordJavaStringIdentity.trim)
        return abbreviation.flatMap { $0.isEmpty ? nil : $0 } ?? config.name
    }

    /**
     Resolves current live payload targets for a driver-aware layout.

     - Parameter layout: Revalidated installed layout.
     - Returns: The module's whole data directory when it exists. Stem layouts delete their parent
       directory exactly like directory layouts because Android's JSword `SwordBookDriver.delete`
       removes the book's location directory, and stem packages ship non-stem files such as
       `BuildModule` scripts and `images/` directories that would otherwise be orphaned.
     - Side effects: Reads canonical path metadata.
     - Throws: Filesystem errors or a data path that is not a directory.
     */
    func payloadTargets(for layout: ModuleStoreInstalledLayout) throws -> [URL] {
        guard fileManager.fileExists(atPath: layout.dataDirectoryURL.path) else { return [] }
        let directoryValues = try layout.dataDirectoryURL.resourceValues(forKeys: [.isDirectoryKey])
        guard directoryValues.isDirectory == true else {
            throw ModuleStoreMutationError.invalidConfiguration(layout.configRelativePath)
        }
        return [layout.dataDirectoryURL]
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
