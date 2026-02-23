// DownloadService.swift — Module download and installation

import Foundation
import Observation
import SwordKit

/// Download progress information.
public struct DownloadProgress: Sendable {
    public let moduleName: String
    public let bytesDownloaded: Int64
    public let totalBytes: Int64?
    public let isComplete: Bool
    public let error: String?

    public var fractionComplete: Double {
        guard let total = totalBytes, total > 0 else { return 0 }
        return Double(bytesDownloaded) / Double(total)
    }
}

/// Manages downloading and installing Bible modules from remote repositories.
@Observable
public final class DownloadService {
    private let swordManager: SwordManager
    private let installManager: InstallManager

    /// Currently active downloads.
    public private(set) var activeDownloads: [String: DownloadProgress] = [:]

    public init(swordManager: SwordManager, installManager: InstallManager) {
        self.swordManager = swordManager
        self.installManager = installManager
    }

    /// Refresh the catalog for a remote source.
    public func refreshSource(_ sourceName: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let result = installManager.refreshSource(sourceName)
            continuation.resume(returning: result)
        }
    }

    /// Get available modules from a source, optionally filtered.
    public func availableModules(
        from sourceName: String,
        category: ModuleCategory? = nil,
        language: String? = nil
    ) -> [RemoteModuleInfo] {
        var modules = installManager.availableModules(from: sourceName)

        if let category {
            modules = modules.filter { $0.category == category }
        }
        if let language {
            modules = modules.filter { $0.language == language }
        }

        return modules
    }

    /// Install a module from a remote source.
    public func install(moduleName: String, from sourceName: String) async -> Bool {
        activeDownloads[moduleName] = DownloadProgress(
            moduleName: moduleName,
            bytesDownloaded: 0,
            totalBytes: nil,
            isComplete: false,
            error: nil
        )

        let success = await withCheckedContinuation { continuation in
            let result = installManager.install(
                moduleName: moduleName,
                from: sourceName,
                into: swordManager
            )
            continuation.resume(returning: result)
        }

        activeDownloads[moduleName] = DownloadProgress(
            moduleName: moduleName,
            bytesDownloaded: 0,
            totalBytes: nil,
            isComplete: true,
            error: success ? nil : "Installation failed"
        )

        if success {
            swordManager.refresh()
        }

        return success
    }

    /// Uninstall a module.
    public func uninstall(moduleName: String) -> Bool {
        let success = installManager.uninstall(moduleName: moduleName, from: swordManager)
        if success {
            swordManager.refresh()
        }
        return success
    }

    /// Get list of remote sources.
    public func remoteSources() -> [RemoteSource] {
        installManager.remoteSources()
    }
}
