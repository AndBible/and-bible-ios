// SwordConfig.swift — SWConfig wrapper for SwordKit

import Foundation
import CLibSword

/**
 Swift wrapper around SWORD's SWConfig for reading/writing configuration files.

 Used to manage sword.conf and module .conf files. Native config calls are routed through
 `SwordRuntime` because the flat SWORD bridge is process-global and not thread-safe.
 */
public final class SwordConfig: @unchecked Sendable {
    private let handle: UnsafeMutableRawPointer

    /// The file path this config was loaded from.
    public let filePath: String

    /**
     Initialize a SwordConfig from a configuration file.
     - Parameter filePath: Path to the .conf file.
     */
    public init?(filePath: String) {
        self.filePath = filePath
        guard let h = SwordRuntime.sync({ SWConfig_new(filePath) }) else { return nil }
        self.handle = h
    }

    deinit {
        SwordRuntime.sync {
            SWConfig_delete(handle)
        }
    }

    /**
     Get a configuration value.
     - Parameters:
       - section: The config section (e.g., "Install").
       - key: The key within the section.
     - Returns: The value, or nil if not found.
     */
    public func getValue(section: String, key: String) -> String? {
        SwordRuntime.sync {
            guard let cStr = SWConfig_getValue(handle, section, key) else { return nil }
            let value = String(cString: cStr)
            return value.isEmpty ? nil : value
        }
    }

    /**
     Set a configuration value.
     - Parameters:
       - section: The config section.
       - key: The key within the section.
       - value: The value to set.
     */
    public func setValue(section: String, key: String, value: String) {
        SwordRuntime.sync {
            SWConfig_setValue(handle, section, key, value)
        }
    }

    /// Save configuration changes to disk.
    public func save() {
        SwordRuntime.sync {
            SWConfig_save(handle)
        }
    }
}
