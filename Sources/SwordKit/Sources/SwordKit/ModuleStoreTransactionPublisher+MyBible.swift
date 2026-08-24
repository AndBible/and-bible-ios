// ModuleStoreTransactionPublisher+MyBible.swift - Transactional MyBible publication

import Foundation

extension ModuleStoreTransactionPublisher {
    /**
     Publishes one staged MyBible directory under the same canonical-root lease as SWORD writers.

     - Parameters:
       - stagingDirectory: Isolated directory containing payload and `module.json`.
       - moduleName: Safe MyBible initials used as the final directory name.
       - onCommitStarted: Callback invoked after cancellation closes and before live-tree work.
     - Side effects: Replaces the live MyBible directory, removes the one proven pre-parity owner in
       the same rollback transaction when present, and posts one notification.
     - Throws: Cancellation before mutation, unsafe paths, missing or identity-mismatched staged
       metadata/payload, or filesystem/rollback errors.
     */
    public func publishStagedMyBibleInstall(
        from stagingDirectory: URL,
        moduleName: String,
        onCommitStarted: (() -> Void)? = nil
    ) throws {
        let safeName = try safeMyBibleDirectoryName(moduleName)
        try coordinator.withExclusiveTransaction(kind: .remoteMyBible, prepare: {
            let stagingCanonical = stagingDirectory.standardizedFileURL.resolvingSymlinksInPath()
            try validateIsolatedStagingRoot(stagingCanonical)
            let stagedMetadataURL = stagingCanonical.appendingPathComponent("module.json")
            guard let stagedMetadataData = try? Data(contentsOf: stagedMetadataURL),
                  let stagedMetadata = try? JSONDecoder().decode(
                    InstalledMyBibleModule.self,
                    from: stagedMetadataData
                  ) else {
                throw ModuleStoreMutationError.stagedFileMissing("module.json")
            }
            let stagedIdentity = MyBibleAndroidFilenameIdentity(
                fileName: stagedMetadata.packageFileName
            )
            guard SwordJavaStringIdentity.equals(stagedMetadata.name, safeName),
                  SwordJavaStringIdentity.equals(stagedIdentity.initials, safeName) else {
                throw ModuleStoreMutationError.invalidConfiguration("module.json")
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
            let obsoleteName = try safeMyBibleDirectoryName(
                MyBibleAndroidFilenameIdentity.obsoletePreParityIOSDirectoryName(
                    forPackageFileName: stagedMetadata.packageFileName
                )
            )
            let obsoleteURL = myBibleRoot.appendingPathComponent(obsoleteName, isDirectory: true)
            try resolver.validateCanonicalContainment(of: obsoleteURL, beneath: myBibleRoot)
            let obsoleteURLs: [URL]
            if SwordJavaExactStringIdentity(obsoleteName) == SwordJavaExactStringIdentity(safeName) {
                obsoleteURLs = []
            } else if let provenObsoleteURL = try obsoleteMyBibleModuleURL(
                obsoleteURL,
                expectedModuleName: obsoleteName,
                expectedPackageFileName: stagedMetadata.packageFileName
            ) {
                obsoleteURLs = [provenObsoleteURL]
            } else {
                obsoleteURLs = []
            }
            return (
                stagingCanonical: stagingCanonical,
                myBibleRoot: myBibleRoot,
                finalURL: finalURL,
                obsoleteURLs: obsoleteURLs
            )
        }, commit: { prepared in
            onCommitStarted?()
            let backupRoot = canonicalRootURL.appendingPathComponent(
                ".module-transaction-\(UUID().uuidString).backup",
                isDirectory: true
            )
            var backupMoves: [BackupMove] = []
            var createdDirectories: [URL] = []
            do {
                try createLiveDirectory(prepared.myBibleRoot, tracking: &createdDirectories)
                for existingURL in [prepared.finalURL] + prepared.obsoleteURLs
                    where fileManager.fileExists(atPath: existingURL.path) {
                    let backupURL = backupRoot.appendingPathComponent(
                        "mybible/\(existingURL.lastPathComponent)",
                        isDirectory: true
                    )
                    try fileManager.createDirectory(
                        at: backupURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try fileManager.moveItem(at: existingURL, to: backupURL)
                    backupMoves.append(
                        BackupMove(originalURL: existingURL, backupURL: backupURL)
                    )
                }
                try fileManager.copyItem(at: prepared.stagingCanonical, to: prepared.finalURL)
                if fileManager.fileExists(atPath: backupRoot.path) {
                    try fileManager.removeItem(at: backupRoot)
                }
                notifyModuleStoreChanged()
            } catch {
                let rollbackFailures = rollback(
                    backupRoot: backupRoot,
                    moves: backupMoves,
                    publishedURLs: [prepared.finalURL],
                    createdDirectories: createdDirectories
                )
                try throwAfterRollback(original: error, rollbackFailures: rollbackFailures)
            }
        })
    }

    /**
     Validates one direct MyBible directory component.

     Android's historical sanitizer deliberately preserves backslash, which is an ordinary filename
     character on iOS rather than a path separator. The general SWORD module validator rejects it
     because archive paths are cross-platform; this family-specific boundary admits it while still
     rejecting every iOS path/control escape.

     - Parameter moduleName: Exact Android-derived MyBible initials.
     - Returns: The unchanged direct component.
     - Side effects: None.
     - Failure modes: Empty, dot, slash, percent, null, or line-break values throw
       `ModuleStoreMutationError.unsafeModuleName`.
     */
    private func safeMyBibleDirectoryName(_ moduleName: String) throws -> String {
        guard !moduleName.isEmpty,
              moduleName != ".",
              moduleName != "..",
              !moduleName.contains("/"),
              !moduleName.contains("%"),
              !moduleName.contains("\0"),
              !moduleName.contains("\n"),
              !moduleName.contains("\r") else {
            throw ModuleStoreMutationError.unsafeModuleName(moduleName)
        }
        return moduleName
    }

    /**
     Resolves an obsolete pre-parity directory only when it belongs to the staged manifest package.

     - Parameters:
       - moduleURL: Canonical-contained candidate directory derived from the old iOS identity.
       - expectedModuleName: Exact pre-parity owner stored in the sidecar before filesystem Unicode
         decomposition.
       - expectedPackageFileName: Exact manifest filename decoded from staged metadata.
     - Returns: The unchanged directory when its valid sidecar names the same exact package, or nil
       when the path is absent or belongs to another package.
     - Side effects: Reads directory and sidecar file metadata plus bounded JSON content.
     - Failure modes: Filesystem metadata errors propagate; symlinks, malformed sidecars, and
       different package identities fail closed without becoming removal targets.
     */
    private func obsoleteMyBibleModuleURL(
        _ moduleURL: URL,
        expectedModuleName: String,
        expectedPackageFileName: String
    ) throws -> URL? {
        guard fileManager.fileExists(atPath: moduleURL.path) else { return nil }
        let directoryValues = try moduleURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard directoryValues.isDirectory == true,
              directoryValues.isSymbolicLink != true else {
            return nil
        }
        let metadataURL = moduleURL.appendingPathComponent("module.json")
        let metadataValues = try metadataURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard metadataValues.isRegularFile == true,
              metadataValues.isSymbolicLink != true,
              let fileSize = metadataValues.fileSize,
              fileSize <= 1_024 * 1_024,
              let data = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode(InstalledMyBibleModule.self, from: data),
              SwordJavaStringIdentity.equals(metadata.name, expectedModuleName),
              fileSystemComponent(
                moduleURL.lastPathComponent,
                representsExactOwner: expectedModuleName
              ),
              SwordJavaStringIdentity.equals(
                metadata.packageFileName,
                expectedPackageFileName
              ) else {
            return nil
        }
        return moduleURL
    }

    /**
     Resolves a valid installed MyBible sidecar without mutating the live tree.

     - Parameter moduleName: Validated MyBible initials.
     Direct sidecar-directory initials are the remote package owner. When visible installed initials
     instead come from the actual database filename, the method scans valid sidecars in
     deterministic raw UTF-16 path order and returns that payload owner.

     - Returns: The contained module directory, or `nil` when no direct or database-derived identity
       matches.
     - Side effects: Reads path/sidecar metadata and opens candidate SQLite payloads read-only under
       the transaction lease.
     - Throws: Canonical-containment, malformed direct-sidecar, or filesystem errors.
     */
    func myBibleModuleURLIfPresent(moduleName: String) throws -> URL? {
        let myBibleRoot = canonicalRootURL.appendingPathComponent("mybible", isDirectory: true)
        try resolver.validateCanonicalContainment(of: myBibleRoot, beneath: canonicalRootURL)
        let moduleURL = myBibleRoot.appendingPathComponent(moduleName, isDirectory: true)
        try resolver.validateCanonicalContainment(of: moduleURL, beneath: myBibleRoot)
        if fileManager.fileExists(atPath: moduleURL.path) {
            let validated = try validatedMyBibleModule(moduleURL, moduleName: moduleName)
            guard SwordJavaStringIdentity.equals(validated.sidecar.name, moduleName) else {
                throw ModuleStoreMutationError.invalidConfiguration(
                    "mybible/\(moduleName)/module.json"
                )
            }
            return validated.url
        }

        guard fileManager.fileExists(atPath: myBibleRoot.path) else { return nil }
        let directories = try fileManager.contentsOfDirectory(
            at: myBibleRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ).sorted {
            Array($0.path.utf16).lexicographicallyPrecedes(Array($1.path.utf16))
        }
        let requestedIdentity = SwordJavaExactStringIdentity(moduleName)
        for directory in directories {
            guard let validated = try? validatedMyBibleModule(
                directory,
                moduleName: moduleName
            ),
                  InstalledMyBibleBookReader.registrations(
                    in: validated.url,
                    sidecar: validated.sidecar
                  ).contains(
                    where: { SwordJavaExactStringIdentity($0.info.name) == requestedIdentity }
                  ) else {
                continue
            }
            return validated.url
        }
        return nil
    }

    /**
     Validates one resolved MyBible sidecar directory before transactional removal.

     - Parameters:
       - moduleURL: Candidate direct or database-derived module directory.
       - moduleName: Requested installed initials used in diagnostics.
     - Returns: The unchanged canonical-contained directory and its decoded sidecar.
     - Side effects: Reads directory and bounded `module.json` metadata.
     - Throws: Invalid/symlink directories, missing/malformed sidecars, and sidecars whose exact
       remote owner differs from the directory component fail closed.
     */
    private func validatedMyBibleModule(
        _ moduleURL: URL,
        moduleName: String
    ) throws -> (url: URL, sidecar: InstalledMyBibleModule) {
        let myBibleRoot = canonicalRootURL.appendingPathComponent("mybible", isDirectory: true)
        try resolver.validateCanonicalContainment(of: moduleURL, beneath: myBibleRoot)
        let moduleValues = try moduleURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard moduleValues.isDirectory == true, moduleValues.isSymbolicLink != true else {
            throw ModuleStoreMutationError.invalidConfiguration("mybible/\(moduleName)")
        }
        let metadataURL = moduleURL.appendingPathComponent("module.json")
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            throw ModuleStoreMutationError.invalidConfiguration("mybible/\(moduleName)/module.json")
        }
        let metadataValues = try metadataURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard metadataValues.isRegularFile == true,
              metadataValues.isSymbolicLink != true,
              let fileSize = metadataValues.fileSize,
              fileSize <= 1_024 * 1_024,
              let data = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode(InstalledMyBibleModule.self, from: data),
              fileSystemComponent(
                moduleURL.lastPathComponent,
                representsExactOwner: metadata.name
              ) else {
            throw ModuleStoreMutationError.invalidConfiguration("mybible/\(moduleName)/module.json")
        }
        return (moduleURL, metadata)
    }

    /**
     Tests whether a URL directory component represents one exact sidecar owner on Apple filesystems.

     Foundation exposes filesystem path components in decomposed Unicode form even when the app
     supplied a composed Java string. The sidecar remains the authoritative raw identity; this
     comparison permits only canonical composition differences needed to bind that identity to its
     storage directory. It deliberately performs no case folding.

     - Parameters:
       - component: Directory component returned by Foundation URL handling.
       - owner: Exact Java-visible owner stored in the sidecar.
     - Returns: `true` only when both strings have identical canonical decomposition.
     - Side effects: None.
     - Failure modes: None; every Swift string supports deterministic canonical decomposition.
     */
    private func fileSystemComponent(
        _ component: String,
        representsExactOwner owner: String
    ) -> Bool {
        SwordJavaStringIdentity.equals(
            component.decomposedStringWithCanonicalMapping,
            owner.decomposedStringWithCanonicalMapping
        )
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
