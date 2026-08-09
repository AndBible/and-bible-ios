// ModuleStoreInstalledLayout.swift - Canonical SWORD layout and staged ownership validation

import Foundation

/**
 Describes whether a SWORD driver's `DataPath` denotes a directory or filename prefix.
 */
public enum ModuleStorePayloadShape: Sendable, Equatable {
    /// Every staged file below the exact data directory belongs to the module.
    case directory

    /// Direct children whose filename starts with the associated stem belong to the module.
    case filenamePrefix(String)
}

/**
 Canonical, driver-aware layout for one SWORD module config.

 URLs are derived component-by-component from validated relative paths. Callers must re-resolve a
 layout under the transaction lease before mutating because symlink state can change after preflight.
 */
public struct ModuleStoreInstalledLayout: Sendable, Equatable {
    /// Module initials from the config section.
    public let moduleName: String

    /// Raw SWORD driver name after whitespace normalization.
    public let driver: String

    /// Canonical config path relative to the SWORD root.
    public let configRelativePath: String

    /// Validated, slash-separated `DataPath` relative to the SWORD root.
    public let dataPath: String

    /// Directory containing this module's payload, relative to the SWORD root.
    public let dataDirectoryRelativePath: String

    /// Driver-aware payload ownership rule.
    public let payloadShape: ModuleStorePayloadShape

    /// Absolute config URL under canonical `mods.d`.
    public let configURL: URL

    /// Absolute payload directory URL under canonical `modules`.
    public let dataDirectoryURL: URL

    /**
     Tests whether one validated archive-relative file is owned by this config.

     - Parameter relativePath: Exact `modules/...` file path.
     - Returns: `true` only for files bound by this layout's directory or filename-prefix rule.
       Stem layouts additionally own nested subdirectories (for example ThML `images/`) because
     SWORD stem modules routinely ship auxiliary directories beside their stem files, while sibling
     stem files sharing the same directory remain protected by the prefix rule.
     - Side effects: none.
     */
    public func ownsPayload(atRelativePath relativePath: String) -> Bool {
        switch payloadShape {
        case .directory:
            return relativePath.hasPrefix(dataDirectoryRelativePath + "/")
        case .filenamePrefix(let prefix):
            let nsPath = relativePath as NSString
            let parent = nsPath.deletingLastPathComponent
            if parent == dataDirectoryRelativePath {
                return nsPath.lastPathComponent.hasPrefix(prefix)
            }
            return parent.hasPrefix(dataDirectoryRelativePath + "/")
        }
    }
}

/**
 One staged `.conf` file supplied to archive validation.

 The relative path preserves archive identity while content is parsed before extraction and again
 from staged storage immediately before publication.
 */
public struct ModuleStoreStagedConfiguration: Sendable, Equatable {
    /// Exact direct-root `mods.d/<initials>.conf` path.
    public let relativePath: String

    /// Decoded config content.
    public let content: String

    /// Creates one staged config input without performing validation.
    public init(relativePath: String, content: String) {
        self.relativePath = relativePath
        self.content = content
    }
}

/**
 Immutable result of binding every staged config to every staged payload file.

 Plans contain only validated relative paths. Publication re-reads staged configs and recreates the
 plan under the exclusive lease, preventing stale preflight or staged-file substitution.
 */
public struct ModuleStoreStagedInstallPlan: Sendable, Equatable {
    /// Config paths in archive order.
    public let configurationRelativePaths: [String]

    /// Payload paths in archive order.
    public let payloadRelativePaths: [String]

    /// Parsed module initials in config order.
    public let moduleNames: [String]

    /// Driver-aware layouts used by package filtering and transaction planning.
    public let layouts: [ModuleStoreInstalledLayout]

    /// Every config and payload file path accepted for publication.
    public var allRelativePaths: [String] {
        payloadRelativePaths + configurationRelativePaths
    }
}

/**
 Rejects unsafe `DataPath` values and binds configs to staged payload files.

 The resolver accepts SWORD's conventional leading `./` only as a prefix, then rejects every other
 dot component, empty component, backslash, percent encoding, absolute path, and non-`modules` root.
 It resolves existing symlinks for the SWORD root, `mods.d`, `modules`, and target directory and
 requires every target to remain a strict descendant of canonical `modules`.
 */
public struct ModuleStoreInstalledLayoutResolver: @unchecked Sendable {
    /** Drivers whose slash-less `DataPath` ends in a filename stem; a trailing slash still denotes a directory. */
    public static let filenamePrefixDrivers: Set<String> = [
        "rawld", "rawld4", "zld", "rawgenbook", "rawfiles",
    ]

    /// Canonical SWORD root used for every derived URL.
    public let canonicalRootURL: URL

    private let fileManager: FileManager

    /**
     Creates a resolver for one canonical SWORD root.

     - Parameters:
       - moduleRootURL: SWORD home containing `mods.d` and `modules`.
       - fileManager: Filesystem implementation used for symlink and staged-file checks.
     - Side effects: Reads existing symlink metadata; creates no files.
     */
    public init(moduleRootURL: URL, fileManager: FileManager = .default) {
        self.canonicalRootURL = moduleRootURL.standardizedFileURL
            .resolvingSymlinksInPath().standardizedFileURL
        self.fileManager = fileManager
    }

    /**
     Parses and resolves one `.conf` file into its only legal installed layout.

     - Parameters:
       - configuration: Config path and content to parse.
       - requireFileNameMatch: Whether the section initials must match the config filename.
     - Returns: A canonical, driver-aware layout.
     - Throws: `ModuleStoreMutationError` for unreadable configs, unsafe initials/paths, filename
       mismatches, or canonical/symlink escapes.
     */
    public func resolve(
        _ configuration: ModuleStoreStagedConfiguration,
        requireFileNameMatch: Bool = true
    ) throws -> ModuleStoreInstalledLayout {
        guard let config = SwordModuleConfig.parse(configuration.content),
              let rawDataPath = rawConfigValue("datapath", content: configuration.content) else {
            throw ModuleStoreMutationError.invalidConfiguration(configuration.relativePath)
        }
        return try resolve(
            moduleName: config.name,
            dataPath: rawDataPath,
            driver: config.modDrv,
            configRelativePath: configuration.relativePath,
            requireFileNameMatch: requireFileNameMatch
        )
    }

    /**
     Resolves catalog or parsed-config values without raw path appends.

     - Parameters:
       - moduleName: Config section initials.
       - dataPath: Raw or parser-normalized SWORD `DataPath`.
       - driver: SWORD `ModDrv` value.
       - configRelativePath: Direct-root config destination.
       - requireFileNameMatch: Whether filename and section initials must match case-insensitively.
     - Returns: Validated canonical layout.
     - Side effects: Resolves existing symlinks.
     - Throws: `ModuleStoreMutationError` for every unsafe or cross-root layout.
     */
    public func resolve(
        moduleName: String,
        dataPath: String,
        driver: String,
        configRelativePath: String,
        requireFileNameMatch: Bool = true
    ) throws -> ModuleStoreInstalledLayout {
        let normalizedName = try safeModuleName(moduleName)
        let normalizedConfigPath = try validateConfigRelativePath(configRelativePath)
        if requireFileNameMatch {
            let configName = ((normalizedConfigPath as NSString).lastPathComponent as NSString)
                .deletingPathExtension
            guard configName.caseInsensitiveCompare(normalizedName) == .orderedSame else {
                throw ModuleStoreMutationError.configNameMismatch(
                    path: normalizedConfigPath,
                    moduleName: normalizedName
                )
            }
        }

        let normalizedDataPath = try validatedDataPath(dataPath, moduleName: normalizedName)
        let components = normalizedDataPath.split(separator: "/").map(String.init)
        let normalizedDriver = driver.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // SWORD distinguishes stem and directory DataPaths by the trailing slash, not the driver
        // alone: font add-ons such as FontPack declare RawGenBook with a trailing-slash DataPath
        // and ship payload in nested subdirectories of that directory.
        let denotesDirectory = dataPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .hasSuffix("/")
        let shape: ModuleStorePayloadShape
        let directoryComponents: [String]
        if Self.filenamePrefixDrivers.contains(normalizedDriver), !denotesDirectory {
            guard components.count >= 3, let prefix = components.last, !prefix.isEmpty else {
                throw ModuleStoreMutationError.unsafeDataPath(
                    moduleName: normalizedName,
                    dataPath: dataPath
                )
            }
            shape = .filenamePrefix(prefix)
            directoryComponents = Array(components.dropLast())
        } else {
            shape = .directory
            directoryComponents = components
        }

        let dataDirectoryRelativePath = directoryComponents.joined(separator: "/")
        let configURL = try containedURL(
            components: normalizedConfigPath.split(separator: "/").map(String.init),
            requiredRootComponent: "mods.d",
            strictDescendantOfRootComponent: false,
            moduleName: normalizedName,
            originalPath: normalizedConfigPath
        )
        let dataDirectoryURL = try containedURL(
            components: directoryComponents,
            requiredRootComponent: "modules",
            strictDescendantOfRootComponent: true,
            moduleName: normalizedName,
            originalPath: dataPath
        )

        return ModuleStoreInstalledLayout(
            moduleName: normalizedName,
            driver: driver.trimmingCharacters(in: .whitespacesAndNewlines),
            configRelativePath: normalizedConfigPath,
            dataPath: normalizedDataPath,
            dataDirectoryRelativePath: dataDirectoryRelativePath,
            payloadShape: shape,
            configURL: configURL,
            dataDirectoryURL: dataDirectoryURL
        )
    }

    /**
     Parses configs and proves a one-to-one ownership relationship for every staged payload.

     - Parameters:
       - configurations: Every direct-root config included in the staged install.
       - payloadRelativePaths: Every direct-root `modules/` file included in the staged install.
     - Returns: An immutable plan accepted by the transaction publisher.
     - Side effects: Resolves existing live-root symlinks; does not mutate files.
     - Throws: `ModuleStoreMutationError` for duplicate initials, duplicate paths, missing payload,
       unrelated payload, overlapping module targets, or unsafe layout.
     */
    public func validateStagedInstall(
        configurations: [ModuleStoreStagedConfiguration],
        payloadRelativePaths: [String]
    ) throws -> ModuleStoreStagedInstallPlan {
        guard !configurations.isEmpty else {
            throw ModuleStoreMutationError.missingConfiguration
        }
        guard !payloadRelativePaths.isEmpty else {
            throw ModuleStoreMutationError.missingPayload("<archive>")
        }

        var seenConfigPaths: Set<String> = []
        var seenNames: Set<String> = []
        var layouts: [ModuleStoreInstalledLayout] = []
        for configuration in configurations {
            let layout = try resolve(configuration)
            let nameKey = filesystemCollisionKey(layout.moduleName)
            guard seenNames.insert(nameKey).inserted else {
                throw ModuleStoreMutationError.duplicateModuleInitials(layout.moduleName)
            }
            let collisionPath = filesystemCollisionKey(configuration.relativePath)
            guard seenConfigPaths.insert(collisionPath).inserted else {
                throw ModuleStoreMutationError.duplicatePath(configuration.relativePath)
            }
            guard !layouts.contains(where: { layoutsOverlap($0, layout) }) else {
                throw ModuleStoreMutationError.overlappingModuleTargets(layout.moduleName)
            }
            layouts.append(layout)
        }

        var seenPayloadPaths: Set<String> = []
        for relativePath in payloadRelativePaths {
            let normalizedPath = try validatePayloadRelativePath(relativePath)
            guard normalizedPath == relativePath else {
                throw ModuleStoreMutationError.unsafeArchivePath(relativePath)
            }
            guard seenPayloadPaths.insert(filesystemCollisionKey(relativePath)).inserted else {
                throw ModuleStoreMutationError.duplicatePath(relativePath)
            }
            let owners = layouts.filter { $0.ownsPayload(atRelativePath: relativePath) }
            guard owners.count == 1 else {
                if owners.isEmpty {
                    throw ModuleStoreMutationError.unownedPayload(relativePath)
                }
                throw ModuleStoreMutationError.overlappingPayloadOwnership(relativePath)
            }
        }

        for layout in layouts {
            guard payloadRelativePaths.contains(where: layout.ownsPayload(atRelativePath:)) else {
                throw ModuleStoreMutationError.missingPayload(layout.moduleName)
            }
        }

        return ModuleStoreStagedInstallPlan(
            configurationRelativePaths: configurations.map(\.relativePath),
            payloadRelativePaths: payloadRelativePaths,
            moduleNames: layouts.map(\.moduleName),
            layouts: layouts
        )
    }

    /**
     Rechecks one resolved layout against current symlink state immediately before mutation.

     - Parameter layout: Previously validated layout.
     - Returns: A newly resolved equivalent layout.
     - Side effects: Reads current filesystem symlink state.
     - Throws: Safety errors when the path no longer resolves inside canonical roots.
     */
    public func revalidate(_ layout: ModuleStoreInstalledLayout) throws -> ModuleStoreInstalledLayout {
        try resolve(
            moduleName: layout.moduleName,
            dataPath: layout.dataPath,
            driver: layout.driver,
            configRelativePath: layout.configRelativePath
        )
    }

    /**
     Validates one arbitrary derived URL remains below the canonical SWORD root.

     - Parameters:
       - url: Existing or planned live-tree URL.
       - requiredRootURL: Canonical subtree root that must contain `url`.
       - strict: Whether equality with the subtree root is forbidden.
     - Side effects: Resolves existing symlinks.
     - Throws: `ModuleStoreMutationError.canonicalPathEscape` on escape or root aliasing.
     */
    public func validateCanonicalContainment(
        of url: URL,
        beneath requiredRootURL: URL,
        strict: Bool = true
    ) throws {
        let root = requiredRootURL.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        let target = url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard (!strict || target.path != root.path), target.path.hasPrefix(prefix) else {
            throw ModuleStoreMutationError.canonicalPathEscape(url.path)
        }
    }

    /** Returns the canonical `modules` subtree after proving it is not a root escape. */
    public func canonicalModulesRootURL() throws -> URL {
        let url = canonicalRootURL.appendingPathComponent("modules", isDirectory: true)
        try validateCanonicalContainment(of: url, beneath: canonicalRootURL)
        return url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }

    /** Returns the canonical `mods.d` subtree after proving it is not a root escape. */
    public func canonicalConfigsRootURL() throws -> URL {
        let url = canonicalRootURL.appendingPathComponent("mods.d", isDirectory: true)
        try validateCanonicalContainment(of: url, beneath: canonicalRootURL)
        return url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }

    /** Rejects path-shaped module initials before they are appended to MyBible or config roots. */
    public func safeModuleName(_ moduleName: String) throws -> String {
        let name = moduleName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.contains("\\"),
              !name.contains("%") else {
            throw ModuleStoreMutationError.unsafeModuleName(moduleName)
        }
        return name
    }

    /** Validates an exact direct-root config path and returns it unchanged. */
    private func validateConfigRelativePath(_ relativePath: String) throws -> String {
        guard !relativePath.contains("\\"), !relativePath.contains("%") else {
            throw ModuleStoreMutationError.unsafeArchivePath(relativePath)
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2,
              components[0] == "mods.d",
              !components[1].isEmpty,
              String(components[1]).hasSuffix(".conf"),
              components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw ModuleStoreMutationError.unsafeArchivePath(relativePath)
        }
        return relativePath
    }

    /** Validates an exact direct-root payload file path and returns it unchanged. */
    private func validatePayloadRelativePath(_ relativePath: String) throws -> String {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.hasSuffix("/"),
              !relativePath.contains("\\"),
              !relativePath.contains("%") else {
            throw ModuleStoreMutationError.unsafeArchivePath(relativePath)
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 3,
              components[0] == "modules",
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw ModuleStoreMutationError.unsafeArchivePath(relativePath)
        }
        return relativePath
    }

    /** Applies lexical `DataPath` validation before any URL is created. */
    private func validatedDataPath(_ rawPath: String, moduleName: String) throws -> String {
        var path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("./") {
            path.removeFirst(2)
        }
        while path.hasSuffix("/") {
            path.removeLast()
        }
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.contains("%") else {
            throw ModuleStoreMutationError.unsafeDataPath(moduleName: moduleName, dataPath: rawPath)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 2,
              components[0] == "modules",
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw ModuleStoreMutationError.unsafeDataPath(moduleName: moduleName, dataPath: rawPath)
        }
        return components.joined(separator: "/")
    }

    /** Builds a component-safe URL and validates its current canonical containment. */
    private func containedURL(
        components: [String],
        requiredRootComponent: String,
        strictDescendantOfRootComponent: Bool,
        moduleName: String,
        originalPath: String
    ) throws -> URL {
        guard components.first == requiredRootComponent else {
            throw ModuleStoreMutationError.unsafeDataPath(
                moduleName: moduleName,
                dataPath: originalPath
            )
        }
        let subtreeURL = canonicalRootURL.appendingPathComponent(requiredRootComponent, isDirectory: true)
        try validateCanonicalContainment(of: subtreeURL, beneath: canonicalRootURL)
        let target = components.dropFirst().reduce(subtreeURL) { partial, component in
            partial.appendingPathComponent(component)
        }
        try validateCanonicalContainment(
            of: target,
            beneath: subtreeURL,
            strict: strictDescendantOfRootComponent
        )
        return target.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }

    /** Reads one raw case-insensitive config value without path normalization. */
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

    /** Compares normalized names and paths using deterministic case-insensitive filesystem rules. */
    func filesystemCollisionKey(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    /** Detects lexical or canonical target overlap that would prevent unique payload ownership. */
    func layoutsOverlap(
        _ lhs: ModuleStoreInstalledLayout,
        _ rhs: ModuleStoreInstalledLayout
    ) -> Bool {
        let lhsDirectory = filesystemCollisionKey(lhs.dataDirectoryURL.standardizedFileURL.path)
        let rhsDirectory = filesystemCollisionKey(rhs.dataDirectoryURL.standardizedFileURL.path)
        switch (lhs.payloadShape, rhs.payloadShape) {
        case (.directory, .directory):
            return lhsDirectory == rhsDirectory
                || lhsDirectory.hasPrefix(rhsDirectory + "/")
                || rhsDirectory.hasPrefix(lhsDirectory + "/")
        case (.directory, .filenamePrefix):
            return rhsDirectory == lhsDirectory || rhsDirectory.hasPrefix(lhsDirectory + "/")
        case (.filenamePrefix, .directory):
            return lhsDirectory == rhsDirectory || lhsDirectory.hasPrefix(rhsDirectory + "/")
        case (.filenamePrefix(let lhsPrefix), .filenamePrefix(let rhsPrefix)):
            guard lhsDirectory == rhsDirectory else { return false }
            let lhsKey = filesystemCollisionKey(lhsPrefix)
            let rhsKey = filesystemCollisionKey(rhsPrefix)
            return lhsKey.hasPrefix(rhsKey) || rhsKey.hasPrefix(lhsKey)
        }
    }
}
