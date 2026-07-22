// InstallManager.swift — InstallMgr wrapper for SwordKit

import Foundation
import CLibSword

/// Information about a remote module source (repository).
public struct RemoteSource: Sendable, Identifiable {
    /// The source name (e.g., "CrossWire").
    public let name: String

    /// Unique identifier (uses source name).
    public var id: String { name }

    public init(name: String) {
        self.name = name
    }
}

/// Installation state for a remote module row.
public enum RemoteModuleAvailability: String, Sendable {
    case installable
    case unavailable
}

/// Information about a remotely available module.
public struct RemoteModuleInfo: Sendable, Identifiable {
    /// Module abbreviation (e.g., "KJV").
    public let name: String

    /// Full description.
    public let description: String

    /// Module category.
    public let category: ModuleCategory

    /// Language code.
    public let language: String

    /// Source repository name.
    public let sourceName: String

    /// Whether this remote catalog row can be installed.
    public let availability: RemoteModuleAvailability

    /// User-visible explanation when the module cannot be installed.
    public let unavailableReason: String?

    /// Remote catalog version used to detect Android-style update availability.
    public let version: String

    /// Remote catalog install size in bytes, when the source reports it.
    public let installSizeBytes: Int64?

    /// Unique identifier.
    public var id: String { "\(sourceName):\(name)" }

    /// Convenience flag for install controls.
    public var isInstallable: Bool { availability == .installable }

    public init(
        name: String,
        description: String,
        category: ModuleCategory,
        language: String,
        sourceName: String,
        availability: RemoteModuleAvailability = .installable,
        unavailableReason: String? = nil,
        version: String = "",
        installSizeBytes: Int64? = nil
    ) {
        self.name = name
        self.description = description
        self.category = category
        self.language = language
        self.sourceName = sourceName
        self.availability = availability
        self.unavailableReason = unavailableReason
        self.version = version
        self.installSizeBytes = installSizeBytes
    }
}

/**
 Android default SWORD repository definition.

 Android stores built-in repositories in `app/src/main/res/raw/repositories.txt` as independent
 package and catalog directories. iOS still writes `InstallMgr.conf` in the legacy SWORD-compatible
 row shape, but this definition is the shared source of truth for Downloads package installs so iOS
 does not reconstruct package URLs from catalog paths later.
 */
private struct AndroidDefaultRepositorySource: Sendable {
    /// Visible repository name from Android.
    let name: String

    /// HTTPS host from Android.
    let host: String

    /// Android package directory used by package ZIP installs.
    let packageDirectory: String

    /// SWORD catalog directory used for `mods.d.tar.gz`.
    let catalogDirectory: String

    /// SWORD-compatible `InstallMgr.conf` row used by local iOS plumbing.
    var installManagerLine: String {
        "HTTPSource=\(name)|\(host)|\(catalogDirectory)"
    }
}

/**
 Swift wrapper around SWORD's InstallMgr for downloading and installing modules.

 All native operations are serialized through `SwordRuntime` since libsword and the flat bridge
 keep process-global state and are not thread-safe.

 Usage:
 ```swift
 let installMgr = InstallManager(basePath: swordPath)
 let sources = installMgr.remoteSources()
 installMgr.refreshSource("CrossWire")
 let modules = installMgr.availableModules(from: "CrossWire")
 ```

 Live module-tree mutation is intentionally owned by `ModuleRepository`, whose transaction
 publisher serializes all writers for the canonical SWORD root.
 */
public final class InstallManager: @unchecked Sendable {
    private static let defaultConfigVersionMarker = "# AndBibleDefaultSourcesVersion=2"

    private static let androidDefaultSources = [
        AndroidDefaultRepositorySource(
            name: "CrossWire",
            host: "crosswire.org",
            packageDirectory: "/ftpmirror/pub/sword/packages/rawzip",
            catalogDirectory: "/ftpmirror/pub/sword/raw"
        ),
        AndroidDefaultRepositorySource(
            name: "Crosswire Beta",
            host: "crosswire.org",
            packageDirectory: "/ftpmirror/pub/sword/betapackages/rawzip",
            catalogDirectory: "/ftpmirror/pub/sword/betaraw"
        ),
        AndroidDefaultRepositorySource(
            name: "AndBible Extra",
            host: "andbible.github.io",
            packageDirectory: "/andbible-extra/zip",
            catalogDirectory: "/andbible-extra"
        ),
        AndroidDefaultRepositorySource(
            name: "AndBible",
            host: "andbible.github.io",
            packageDirectory: "/data/andbible/zip",
            catalogDirectory: "/data/andbible"
        ),
        AndroidDefaultRepositorySource(
            name: "AndBible Beta",
            host: "andbible.github.io",
            packageDirectory: "/data/andbible/beta/zip",
            catalogDirectory: "/data/andbible/beta"
        ),
        AndroidDefaultRepositorySource(
            name: "IBT",
            host: "ibtrussia.org",
            packageDirectory: "/ftpmirror/pub/modsword/rawzip",
            catalogDirectory: "/ftpmirror/pub/modsword/raw"
        ),
        AndroidDefaultRepositorySource(
            name: "Wycliffe (CrossWire)",
            host: "crosswire.org",
            packageDirectory: "/ftpmirror/pub/sword/wycliffepackages/rawzip",
            catalogDirectory: "/ftpmirror/pub/sword/wyclifferaw"
        ),
        AndroidDefaultRepositorySource(
            name: "eBible",
            host: "ebible.org",
            packageDirectory: "/sword/zip",
            catalogDirectory: "/sword"
        ),
        AndroidDefaultRepositorySource(
            name: "Lockman (CrossWire)",
            host: "crosswire.org",
            packageDirectory: "/ftpmirror/pub/sword/lockmanpackages",
            catalogDirectory: "/ftpmirror/pub/sword/lockmanraw"
        ),
        AndroidDefaultRepositorySource(
            name: "STEP Bible (Tyndale)",
            host: "public.modules.stepbible.org",
            packageDirectory: "/packages",
            catalogDirectory: "/catalog"
        )
    ]

    private static let defaultSourceLines = androidDefaultSources.map(\.installManagerLine) + [
        "FTPSource=CrossWire|ftp.crosswire.org|/pub/sword/raw",
    ]

    private static let upgradeSourceLines = [
        "HTTPSource=AndBible|andbible.github.io|/data/andbible",
        "HTTPSource=AndBible Beta|andbible.github.io|/data/andbible/beta",
    ]

    private let handle: UnsafeMutableRawPointer

    /// The base path for install manager data.
    public let basePath: String

    /**
     Initialize an InstallManager.
     - Parameter basePath: Path for install manager data (catalog cache, etc.).
     */
    public init?(basePath: String? = nil) {
        let path = basePath ?? InstallManager.defaultBasePath()
        self.basePath = path

        // Ensure default remote sources config exists
        InstallManager.ensureDefaultConfig(at: path)

        guard let h = SwordRuntime.sync({ InstallMgr_new(path) }) else { return nil }
        self.handle = h

        // Accept disclaimer to enable remote operations
        SwordRuntime.sync {
            InstallMgr_setUserDisclaimerConfirmed(h)
        }
    }

    deinit {
        SwordRuntime.sync {
            InstallMgr_delete(handle)
        }
    }

    /// Default base path for InstallManager data.
    public static func defaultBasePath() -> String {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let installDir = documents.appendingPathComponent("sword_install", isDirectory: true)
        try? FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)
        return installDir.path
    }

    /**
     Write default InstallMgr.conf with sources matching Android AndBible.
     Sources are from and-bible/app/src/main/res/raw/repositories.txt
     Public entry point for ModuleRepository to use.
     */
    public static func ensureDefaultConfigPublic(at basePath: String) {
        ensureDefaultConfig(at: basePath)
    }

    /**
     Tests whether a repository name belongs to the packaged Android-parity default source set.

     - Parameter name: Repository display name from an `HTTPSource` or `FTPSource` config row.
     - Returns: `true` when the name is one of the built-in normal, beta, or legacy FTP sources.

     Side effects:
     - none
     */
    public static func isDefaultSourceName(_ name: String) -> Bool {
        defaultSourceLines.compactMap(Self.sourceName).contains(name)
    }

    /**
     Returns Android's package directory for a built-in SWORD repository.

     - Parameter source: Parsed iOS source row.
     - Returns: The package directory from Android's `repositories.txt` when the source matches a
       built-in normal or beta repository; otherwise `nil`.
     - Side effects: none.
     - Failure modes: none.
     */
    public static func defaultPackageDirectory(for source: SourceConfig) -> String? {
        androidDefaultSources.first {
            $0.name == source.name &&
                $0.host == source.host &&
                $0.catalogDirectory == source.catalogPath
        }?.packageDirectory
    }

    /**
     Write default InstallMgr.conf with sources matching Android AndBible.
     Sources are from and-bible/app/src/main/res/raw/repositories.txt
     */
    static func ensureDefaultConfig(at basePath: String) {
        let configPath = (basePath as NSString).appendingPathComponent("InstallMgr.conf")
        let fm = FileManager.default

        guard !fm.fileExists(atPath: configPath) else {
            migrateDefaultConfigIfNeeded(at: configPath)
            return
        }

        // Sources matching AndBible Android's repositories.txt, in priority order.
        // Format: HTTPSource=Label|host|catalogDirectory for SWORD compatibility.
        let config = """
        [General]
        PassiveFTP=true

        [Sources]
        \(Self.defaultConfigVersionMarker)
        \(Self.defaultSourceLines.joined(separator: "\n"))
        """

        try? config.write(toFile: configPath, atomically: true, encoding: .utf8)
    }

    private static func migrateDefaultConfigIfNeeded(at configPath: String) {
        guard var content = try? String(contentsOfFile: configPath, encoding: .utf8),
              !content.contains(Self.defaultConfigVersionMarker) else {
            return
        }

        let existingSourceNames = Self.sourceNames(in: content)
        let missingLines = Self.upgradeSourceLines.filter { line in
            guard let sourceName = Self.sourceName(in: line) else { return false }
            return !existingSourceNames.contains(sourceName)
        }

        guard !missingLines.isEmpty else {
            content = Self.insertingSourceLines([Self.defaultConfigVersionMarker], into: content)
            try? content.write(toFile: configPath, atomically: true, encoding: .utf8)
            return
        }

        content = Self.insertingSourceLines([Self.defaultConfigVersionMarker] + missingLines, into: content)
        try? content.write(toFile: configPath, atomically: true, encoding: .utf8)
    }

    private static func insertingSourceLines(_ lines: [String], into content: String) -> String {
        guard !lines.isEmpty else { return content }

        var configLines = content.components(separatedBy: .newlines)
        let sourcesIndex = configLines.firstIndex {
            $0.trimmingCharacters(in: .whitespaces) == "[Sources]"
        }

        var insertionIndex = configLines.endIndex
        if let sourcesIndex {
            insertionIndex = configLines[configLines.index(after: sourcesIndex)...]
                .firstIndex { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    return trimmed.hasPrefix("[") && trimmed.hasSuffix("]")
                } ?? configLines.endIndex
        }

        if insertionIndex == configLines.endIndex,
           configLines.last == "" {
            insertionIndex = configLines.index(before: configLines.endIndex)
        }

        configLines.insert(contentsOf: lines, at: insertionIndex)
        var updated = configLines.joined(separator: "\n")
        if !updated.hasSuffix("\n") { updated += "\n" }
        return updated
    }

    private static func sourceNames(in content: String) -> Set<String> {
        Set(content.components(separatedBy: .newlines).compactMap { Self.sourceName(in: $0) })
    }

    private static func sourceName(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("HTTPSource=") || trimmed.hasPrefix("FTPSource=") else {
            return nil
        }
        let value = String(trimmed.drop(while: { $0 != "=" }).dropFirst())
        return value.components(separatedBy: "|").first
    }

    // MARK: - Remote Sources

    /// List configured remote sources.
    public func remoteSources() -> [RemoteSource] {
        SwordRuntime.sync {
            let count = InstallMgr_getRemoteSourceCount(handle)
            var sources: [RemoteSource] = []
            sources.reserveCapacity(Int(count))

            for i in 0..<count {
                guard let namePtr = InstallMgr_getRemoteSourceName(handle, i) else { continue }
                sources.append(RemoteSource(name: String(cString: namePtr)))
            }

            return sources
        }
    }

    /**
     Refresh the module catalog for a remote source.
     - Parameter sourceName: The source to refresh.
     - Returns: `true` if the refresh succeeded.
     */
    @discardableResult
    public func refreshSource(_ sourceName: String) -> Bool {
        SwordRuntime.sync {
            InstallMgr_refreshRemoteSource(handle, sourceName) == 0
        }
    }

    // MARK: - Available Modules

    /**
     List modules available from a remote source.
     - Parameter sourceName: The source to query.
     - Returns: List of available modules.
     */
    public func availableModules(from sourceName: String) -> [RemoteModuleInfo] {
        SwordRuntime.sync {
            let count = InstallMgr_getRemoteModuleCount(handle, sourceName)
            var modules: [RemoteModuleInfo] = []
            modules.reserveCapacity(Int(count))

            for i in 0..<count {
                guard let namePtr = InstallMgr_getRemoteModuleName(handle, sourceName, i) else { continue }
                let name = String(cString: namePtr)
                let descPtr = InstallMgr_getRemoteModuleDescription(handle, sourceName, i)
                let desc = descPtr != nil ? String(cString: descPtr!) : ""
                let typePtr = InstallMgr_getRemoteModuleType(handle, sourceName, i)
                let type = typePtr != nil ? String(cString: typePtr!) : ""
                let langPtr = InstallMgr_getRemoteModuleLanguage(handle, sourceName, i)
                let lang = langPtr != nil ? String(cString: langPtr!) : ""

                guard !name.isEmpty else { continue }

                modules.append(RemoteModuleInfo(
                    name: name,
                    description: desc,
                    category: ModuleCategory(typeString: type),
                    language: lang,
                    sourceName: sourceName
                ))
            }

            return modules
        }
    }

    /// List available modules filtered by category.
    public func availableModules(from sourceName: String, category: ModuleCategory) -> [RemoteModuleInfo] {
        availableModules(from: sourceName).filter { $0.category == category }
    }

    /// List available modules filtered by language.
    public func availableModules(from sourceName: String, language: String) -> [RemoteModuleInfo] {
        availableModules(from: sourceName).filter { $0.language == language }
    }

}
