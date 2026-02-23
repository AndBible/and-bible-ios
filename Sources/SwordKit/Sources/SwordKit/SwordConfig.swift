// SwordConfig.swift — SWConfig wrapper for SwordKit

import Foundation
import CLibSword

/// Swift wrapper around SWORD's SWConfig for reading/writing configuration files.
///
/// Used to manage sword.conf and module .conf files.
public final class SwordConfig: @unchecked Sendable {
    private let handle: UnsafeMutableRawPointer
    private let queue = DispatchQueue(label: "org.andbible.SwordConfig", qos: .userInitiated)

    /// The file path this config was loaded from.
    public let filePath: String

    /// Initialize a SwordConfig from a configuration file.
    /// - Parameter filePath: Path to the .conf file.
    public init?(filePath: String) {
        self.filePath = filePath
        guard let h = SWConfig_new(filePath) else { return nil }
        self.handle = h
    }

    deinit {
        SWConfig_delete(handle)
    }

    /// Get a configuration value.
    /// - Parameters:
    ///   - section: The config section (e.g., "Install").
    ///   - key: The key within the section.
    /// - Returns: The value, or nil if not found.
    public func getValue(section: String, key: String) -> String? {
        queue.sync {
            guard let cStr = SWConfig_getValue(handle, section, key) else { return nil }
            let value = String(cString: cStr)
            return value.isEmpty ? nil : value
        }
    }

    /// Set a configuration value.
    /// - Parameters:
    ///   - section: The config section.
    ///   - key: The key within the section.
    ///   - value: The value to set.
    public func setValue(section: String, key: String, value: String) {
        queue.sync {
            SWConfig_setValue(handle, section, key, value)
        }
    }

    /// Save configuration changes to disk.
    public func save() {
        queue.sync {
            SWConfig_save(handle)
        }
    }
}
