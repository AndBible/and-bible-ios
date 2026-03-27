// SwordManager.swift — SWMgr wrapper for SwordKit

import Foundation
import CLibSword

/**
 Swift wrapper around SWORD's SWMgr (module manager).

 Manages the SWORD module installation directory, provides access to
 installed modules, and controls global rendering options.

 All libsword operations are serialized on an internal queue since
 the library is not thread-safe.

 Usage:
 ```swift
 let manager = SwordManager(modulePath: "/path/to/sword/modules")
 let modules = manager.installedModules()
 if let kjv = manager.module(named: "KJV") {
     kjv.setKey("Gen 1:1")
     let text = kjv.renderText()
 }
 ```
 */
public final class SwordManager: @unchecked Sendable {
    private let handle: UnsafeMutableRawPointer
    private let queue = DispatchQueue(label: "org.andbible.SwordManager", qos: .userInitiated)

    /// Internal access to the C handle for InstallManager operations.
    var rawHandle: UnsafeMutableRawPointer { handle }
    private var moduleCache: [String: SwordModule] = [:]

    /// The filesystem path where SWORD modules are installed.
    public let modulePath: String

    /**
     Initialize a SwordManager with the given module path.
     - Parameter modulePath: Path to the SWORD modules directory.
       Pass nil to use the default system path.
     */
    public init?(modulePath: String? = nil) {
        let path = modulePath ?? SwordManager.defaultModulePath()
        self.modulePath = path

        guard let h = SWMgr_new(path) else { return nil }
        self.handle = h
    }

    deinit {
        moduleCache.removeAll()
        SWMgr_delete(handle)
    }

    /// Default path for SWORD modules in the app's documents directory.
    public static func defaultModulePath() -> String {
        let fileManager = FileManager.default
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let swordDir = documents.appendingPathComponent("sword", isDirectory: true)

        // Ensure the directory exists
        try? fileManager.createDirectory(at: swordDir, withIntermediateDirectories: true)

        return swordDir.path
    }

    // MARK: - Module Listing

    /// Get the number of installed modules.
    public var moduleCount: Int {
        queue.sync {
            Int(SWMgr_getModuleCount(handle))
        }
    }

    /// List all installed modules.
    public func installedModules() -> [ModuleInfo] {
        queue.sync {
            let count = SWMgr_getModuleCount(handle)
            var modules: [ModuleInfo] = []
            modules.reserveCapacity(Int(count))

            for i in 0..<count {
                guard let namePtr = SWMgr_getModuleNameByIndex(handle, i) else { continue }
                let name = String(cString: namePtr)
                guard let modHandle = SWMgr_getModuleByName(handle, name) else { continue }

                let mod = getOrCreateModule(name: name, handle: modHandle)
                modules.append(mod.info)
            }

            return modules
        }
    }

    /// List installed modules filtered by category.
    public func installedModules(category: ModuleCategory) -> [ModuleInfo] {
        installedModules().filter { $0.category == category }
    }

    /**
     Get a module by name.
     - Parameter name: The module abbreviation (e.g., "KJV").
     - Returns: The module, or nil if not installed.
     */
    public func module(named name: String) -> SwordModule? {
        queue.sync {
            if let cached = moduleCache[name] { return cached }
            guard let modHandle = SWMgr_getModuleByName(handle, name) else { return nil }
            return getOrCreateModule(name: name, handle: modHandle)
        }
    }

    private func getOrCreateModule(name: String, handle: UnsafeMutableRawPointer) -> SwordModule {
        if let cached = moduleCache[name] { return cached }
        let mod = SwordModule(handle: handle, queue: queue, modulePath: modulePath)
        moduleCache[name] = mod
        return mod
    }

    // MARK: - Global Options

    /// Global rendering options that can be toggled.
    public enum GlobalOption: String, CaseIterable {
        case strongsNumbers = "Strong's Numbers"
        case morphology = "Morphological Tags"
        case footnotes = "Footnotes"
        case headings = "Headings"
        case crossReferences = "Cross-references"
        case redLetterWords = "Words of Christ in Red"
        case glosses = "Glosses"
        case morphSegmentation = "Morpheme Segmentation"
    }

    /**
     Set a global rendering option.
     - Parameters:
       - option: The option to set.
       - enabled: Whether the option should be enabled.
     */
    public func setGlobalOption(_ option: GlobalOption, enabled: Bool) {
        queue.sync {
            SWMgr_setGlobalOption(handle, option.rawValue, enabled ? "On" : "Off")
        }
    }

    /**
     Get the current value of a global rendering option.
     - Parameter option: The option to query.
     - Returns: Whether the option is currently enabled.
     */
    public func isGlobalOptionEnabled(_ option: GlobalOption) -> Bool {
        queue.sync {
            guard let value = SWMgr_getGlobalOption(handle, option.rawValue) else { return false }
            return String(cString: value) == "On"
        }
    }

    // MARK: - Paths

    /// The configuration path used by the manager.
    public var configPath: String {
        queue.sync {
            guard let path = SWMgr_getConfigPath(handle) else { return "" }
            return String(cString: path)
        }
    }

    /// The prefix path (module install root).
    public var prefixPath: String {
        queue.sync {
            guard let path = SWMgr_getPrefixPath(handle) else { return "" }
            return String(cString: path)
        }
    }

    // MARK: - Module Refresh

    /**
     Re-scan the module directory for changes.
     Call after installing or uninstalling modules.
     */
    public func refresh() {
        queue.sync {
            moduleCache.removeAll()
        }
        // Recreate is the simplest way to refresh libsword's module list.
        // The caller should create a new SwordManager instance for a full refresh.
    }
}
