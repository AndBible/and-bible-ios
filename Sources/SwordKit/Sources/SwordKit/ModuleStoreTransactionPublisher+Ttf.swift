// ModuleStoreTransactionPublisher+Ttf.swift - Transactional app-owned TTF addon publication

import Foundation

extension ModuleStoreTransactionPublisher {
    /**
     Publishes one generated TTF addon config and optional staged font through the shared lease.

     Passing no staged font is the startup-registration path: the existing live font is revalidated
     and only its missing or stale generated config is replaced. Config publication remains last.

     - Parameters:
       - font: Sanitized addon identity and destination filename.
       - stagedFontURL: Isolated staged font payload, or `nil` when registering an existing font.
       - configContent: Generated Android-parity addon config.
     - Side effects: Transactionally replaces font/config files, invalidates the module cache, and
       posts the module-store notification while holding the canonical-root lease.
     - Throws: Safety, cancellation-before-mutation, filesystem, or rollback failures.
     */
    func publishTtfAddon(
        _ font: InstalledTtfFont,
        stagedFontURL: URL?,
        configContent: String
    ) throws {
        let moduleName = try resolver.safeModuleName(font.moduleName)
        let fileName = try validatedTtfFileName(font.fileName)
        let relativePathComponents = try validatedTtfRelativePath(
            font.relativePath,
            fileName: fileName
        )
        let parentComponents = relativePathComponents.dropLast()
        let expectedDataPath = parentComponents.isEmpty
            ? "ttf/"
            : "ttf/\(parentComponents.joined(separator: "/"))/"
        try validateTtfConfig(
            configContent,
            moduleName: moduleName,
            fileName: fileName,
            expectedDataPath: expectedDataPath
        )

        try coordinator.withExclusiveTransaction(kind: .ttfAddon, prepare: {
            try validateTtfConfig(
                configContent,
                moduleName: moduleName,
                fileName: fileName,
                expectedDataPath: expectedDataPath
            )
            let fontsRoot = canonicalRootURL.appendingPathComponent("ttf", isDirectory: true)
            try resolver.validateCanonicalContainment(of: fontsRoot, beneath: canonicalRootURL)
            let finalFontURL = relativePathComponents.reduce(fontsRoot) {
                $0.appendingPathComponent($1)
            }
            try resolver.validateCanonicalContainment(of: finalFontURL, beneath: fontsRoot)
            let configsRoot = try resolver.canonicalConfigsRootURL()
            let finalConfigURL = configsRoot.appendingPathComponent(
                "\(moduleName.lowercased()).conf"
            )
            try resolver.validateCanonicalContainment(of: finalConfigURL, beneath: configsRoot)

            let canonicalStagedFont: URL?
            if let stagedFontURL {
                let staged = stagedFontURL.standardizedFileURL.resolvingSymlinksInPath()
                try validateIsolatedStagingRoot(staged)
                let values = try stagedFontURL.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw ModuleStoreMutationError.stagedFileMissing(fileName)
                }
                canonicalStagedFont = staged
            } else {
                try validateExistingTtfFile(
                    finalFontURL,
                    description: "ttf/\(font.relativePath)"
                )
                canonicalStagedFont = nil
            }

            if fileManager.fileExists(atPath: finalFontURL.path) {
                try validateExistingTtfFile(
                    finalFontURL,
                    description: "ttf/\(font.relativePath)"
                )
            }
            if fileManager.fileExists(atPath: finalConfigURL.path) {
                let values = try finalConfigURL.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw ModuleStoreMutationError.invalidConfiguration(
                        "mods.d/\(moduleName.lowercased()).conf"
                    )
                }
            }
            return (
                fontsRoot: fontsRoot,
                configsRoot: configsRoot,
                finalFontURL: finalFontURL,
                finalConfigURL: finalConfigURL,
                stagedFontURL: canonicalStagedFont
            )
        }, commit: { prepared in
            let backupRoot = canonicalRootURL.appendingPathComponent(
                ".module-transaction-\(UUID().uuidString).backup",
                isDirectory: true
            )
            var moves: [BackupMove] = []
            var publishedURLs: [URL] = []
            var createdDirectories: [URL] = []
            do {
                try createLiveDirectory(prepared.fontsRoot, tracking: &createdDirectories)
                try createLiveDirectory(prepared.configsRoot, tracking: &createdDirectories)
                if let stagedFontURL = prepared.stagedFontURL {
                    try createLiveDirectory(
                        prepared.finalFontURL.deletingLastPathComponent(),
                        tracking: &createdDirectories
                    )
                    try moveToBackup(prepared.finalFontURL, backupRoot: backupRoot, moves: &moves)
                    publishedURLs.append(prepared.finalFontURL)
                    try fileManager.copyItem(at: stagedFontURL, to: prepared.finalFontURL)
                }

                let temporaryConfigURL = prepared.configsRoot.appendingPathComponent(
                    ".module-config-\(UUID().uuidString).tmp"
                )
                try resolver.validateCanonicalContainment(
                    of: temporaryConfigURL,
                    beneath: prepared.configsRoot
                )
                publishedURLs.append(temporaryConfigURL)
                try Data(configContent.utf8).write(to: temporaryConfigURL, options: .atomic)
                try moveToBackup(prepared.finalConfigURL, backupRoot: backupRoot, moves: &moves)
                publishedURLs.append(prepared.finalConfigURL)
                try fileManager.moveItem(at: temporaryConfigURL, to: prepared.finalConfigURL)

                try invalidateModuleCache()
                if fileManager.fileExists(atPath: backupRoot.path) {
                    try fileManager.removeItem(at: backupRoot)
                }
                notifyModuleStoreChanged()
            } catch {
                let rollbackFailures = rollback(
                    backupRoot: backupRoot,
                    moves: moves,
                    publishedURLs: publishedURLs,
                    createdDirectories: createdDirectories
                )
                try throwAfterRollback(original: error, rollbackFailures: rollbackFailures)
            }
        })
    }

    /** Validates one leaf `.ttf` filename before any destination URL is created. */
    private func validatedTtfFileName(_ rawName: String) throws -> String {
        guard !rawName.isEmpty,
              rawName != ".",
              rawName != "..",
              rawName == (rawName as NSString).lastPathComponent,
              !rawName.contains("\\"),
              !rawName.contains("%"),
              rawName.lowercased().hasSuffix(".ttf") else {
            throw ModuleStoreMutationError.unsafeArchivePath(rawName)
        }
        return rawName
    }

    /**
     Validates one exact path beneath Android's recursive `ttf/` resource root.

     - Parameters:
       - rawPath: Forward-slash path retained by `InstalledTtfFont`.
       - fileName: Already validated final filename that must terminate the path.
     - Returns: Safe path components for containment-preserving URL construction.
     - Side effects: none.
     - Throws: `ModuleStoreMutationError.unsafeArchivePath` for traversal, alternate separators,
       percent escapes, empty components, or a basename mismatch.
     */
    private func validatedTtfRelativePath(
        _ rawPath: String,
        fileName: String
    ) throws -> [String] {
        let components = rawPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.last == fileName,
              components.allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\")
                      && !$0.contains("%") && !$0.contains("\0")
              }) else {
            throw ModuleStoreMutationError.unsafeArchivePath(rawPath)
        }
        return components
    }

    /** Proves generated config identity, driver, payload root, and provided font agree. */
    private func validateTtfConfig(
        _ content: String,
        moduleName: String,
        fileName: String,
        expectedDataPath: String
    ) throws {
        guard let config = SwordModuleConfig.parse(content),
              config.name.caseInsensitiveCompare(moduleName) == .orderedSame,
              config.modDrv.caseInsensitiveCompare("RawGenBook") == .orderedSame,
              config.dataPath == expectedDataPath,
              let provider = config.values["andbibleprovidesfont"]?.first else {
            throw ModuleStoreMutationError.invalidConfiguration(
                "mods.d/\(moduleName.lowercased()).conf"
            )
        }
        let providerParts = provider.split(
            separator: ";",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard providerParts.count == 2, String(providerParts[1]) == fileName else {
            throw ModuleStoreMutationError.invalidConfiguration(
                "mods.d/\(moduleName.lowercased()).conf"
            )
        }
    }

    /** Rejects missing, non-file, or symlinked live font payloads under the transaction lease. */
    private func validateExistingTtfFile(_ url: URL, description: String) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ModuleStoreMutationError.invalidConfiguration(description)
        }
    }
}
