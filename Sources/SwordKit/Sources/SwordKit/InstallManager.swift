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

    /// Unique identifier.
    public var id: String { "\(sourceName):\(name)" }

    public init(
        name: String,
        description: String,
        category: ModuleCategory,
        language: String,
        sourceName: String
    ) {
        self.name = name
        self.description = description
        self.category = category
        self.language = language
        self.sourceName = sourceName
    }
}

/// Swift wrapper around SWORD's InstallMgr for downloading and installing modules.
///
/// All operations are serialized since libsword is not thread-safe.
///
/// Usage:
/// ```swift
/// let installMgr = InstallManager(basePath: swordPath)
/// let sources = installMgr.remoteSources()
/// installMgr.refreshSource("CrossWire")
/// let modules = installMgr.availableModules(from: "CrossWire")
/// installMgr.install(moduleName: "KJV", from: "CrossWire", into: swordManager)
/// ```
public final class InstallManager: @unchecked Sendable {
    private let handle: UnsafeMutableRawPointer
    private let queue = DispatchQueue(label: "org.andbible.InstallManager", qos: .userInitiated)

    /// The base path for install manager data.
    public let basePath: String

    /// Initialize an InstallManager.
    /// - Parameter basePath: Path for install manager data (catalog cache, etc.).
    public init?(basePath: String? = nil) {
        let path = basePath ?? InstallManager.defaultBasePath()
        self.basePath = path

        // Ensure default remote sources config exists
        InstallManager.ensureDefaultConfig(at: path)

        guard let h = InstallMgr_new(path) else { return nil }
        self.handle = h

        // Accept disclaimer to enable remote operations
        InstallMgr_setUserDisclaimerConfirmed(h)
    }

    deinit {
        InstallMgr_delete(handle)
    }

    /// Default base path for InstallManager data.
    public static func defaultBasePath() -> String {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let installDir = documents.appendingPathComponent("sword_install", isDirectory: true)
        try? FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)
        return installDir.path
    }

    /// Write default InstallMgr.conf with sources matching Android AndBible.
    /// Sources are from and-bible/app/src/main/res/raw/repositories.txt
    /// Public entry point for ModuleRepository to use.
    public static func ensureDefaultConfigPublic(at basePath: String) {
        ensureDefaultConfig(at: basePath)
    }

    /// Write default InstallMgr.conf with sources matching Android AndBible.
    /// Sources are from and-bible/app/src/main/res/raw/repositories.txt
    static func ensureDefaultConfig(at basePath: String) {
        let configPath = (basePath as NSString).appendingPathComponent("InstallMgr.conf")
        let fm = FileManager.default

        guard !fm.fileExists(atPath: configPath) else { return }

        // Sources matching AndBible Android's repositories.txt, in priority order.
        // Format: HTTPSource=Label|host|catalogDirectory
        let config = """
        [General]
        PassiveFTP=true

        [Sources]
        HTTPSource=CrossWire|crosswire.org|/ftpmirror/pub/sword/raw
        HTTPSource=eBible|ebible.org|/sword
        HTTPSource=Lockman (CrossWire)|crosswire.org|/ftpmirror/pub/sword/lockmanraw
        HTTPSource=Wycliffe (CrossWire)|crosswire.org|/ftpmirror/pub/sword/wyclifferaw
        HTTPSource=AndBible Extra|andbible.github.io|/andbible-extra
        HTTPSource=IBT|ibtrussia.org|/ftpmirror/pub/modsword/raw
        HTTPSource=STEP Bible (Tyndale)|public.modules.stepbible.org|/catalog
        HTTPSource=Crosswire Beta|crosswire.org|/ftpmirror/pub/sword/betaraw
        FTPSource=CrossWire|ftp.crosswire.org|/pub/sword/raw
        """

        try? config.write(toFile: configPath, atomically: true, encoding: .utf8)
    }

    // MARK: - Remote Sources

    /// List configured remote sources.
    public func remoteSources() -> [RemoteSource] {
        queue.sync {
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

    /// Refresh the module catalog for a remote source.
    /// - Parameter sourceName: The source to refresh.
    /// - Returns: `true` if the refresh succeeded.
    @discardableResult
    public func refreshSource(_ sourceName: String) -> Bool {
        queue.sync {
            InstallMgr_refreshRemoteSource(handle, sourceName) == 0
        }
    }

    // MARK: - Available Modules

    /// List modules available from a remote source.
    /// - Parameter sourceName: The source to query.
    /// - Returns: List of available modules.
    public func availableModules(from sourceName: String) -> [RemoteModuleInfo] {
        queue.sync {
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

    // MARK: - Install / Uninstall

    /// Install a module from a remote source.
    /// - Parameters:
    ///   - moduleName: The module abbreviation to install.
    ///   - sourceName: The remote source to download from.
    ///   - manager: The SwordManager to install into.
    /// - Returns: `true` if installation succeeded.
    @discardableResult
    public func install(moduleName: String, from sourceName: String, into manager: SwordManager) -> Bool {
        // Note: This blocks until download completes. Call from a background task.
        let mgrHandle = manager.rawHandle
        return queue.sync {
            InstallMgr_installModule(handle, mgrHandle, sourceName, moduleName) == 0
        }
    }

    /// Uninstall a module.
    /// - Parameters:
    ///   - moduleName: The module abbreviation to uninstall.
    ///   - manager: The SwordManager the module is installed in.
    /// - Returns: `true` if uninstallation succeeded.
    @discardableResult
    public func uninstall(moduleName: String, from manager: SwordManager) -> Bool {
        let mgrHandle = manager.rawHandle
        return queue.sync {
            InstallMgr_uninstallModule(handle, mgrHandle, moduleName) == 0
        }
    }
}
