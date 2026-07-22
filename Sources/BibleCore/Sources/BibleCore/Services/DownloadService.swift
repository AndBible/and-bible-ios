// DownloadService.swift — Module download and installation

import Foundation
import Observation
import SwordKit

/// Download progress information.
public struct DownloadProgress: Sendable {
    /// Module abbreviation being downloaded.
    public let moduleName: String
    /// Bytes downloaded so far, when known.
    public let bytesDownloaded: Int64
    /// Total expected byte count, when known.
    public let totalBytes: Int64?
    /// Whether the download/install operation has finished.
    public let isComplete: Bool
    /// User-visible error message for failed operations, when available.
    public let error: String?

    /// Fractional completion in the range `0...1` when `totalBytes` is known.
    public var fractionComplete: Double {
        guard let total = totalBytes, total > 0 else { return 0 }
        return Double(bytesDownloaded) / Double(total)
    }
}

/**
 Exposes legacy `InstallManager` source refresh and catalog reads to BibleCore.

 Module mutation deliberately does not live here. Every install and uninstall must enter through
 `ModuleRepository` so it shares the canonical-root transaction coordinator.
 */
@Observable
public final class DownloadService {
    private let installManager: InstallManager

    /**
     Creates a catalog-only download service.

     - Parameter installManager: SwordKit source/catalog reader.
     - Side effects: none.
     - Failure modes: none.
     */
    public init(installManager: InstallManager) {
        self.installManager = installManager
    }

    /**
     Preserves the former construction shape for source/catalog clients.

     - Parameters:
       - swordManager: Ignored legacy parameter; mutation is repository-owned.
       - installManager: SwordKit source/catalog reader.
     - Side effects: none.
     - Failure modes: none.
     */
    @available(*, deprecated, message: "Use init(installManager:); mutate modules through ModuleRepository")
    public convenience init(swordManager _: SwordManager, installManager: InstallManager) {
        self.init(installManager: installManager)
    }

    /**
     Refreshes the remote catalog for a configured source.
     - Parameter sourceName: Source/repository name such as `CrossWire`.
     - Returns: `true` on success, otherwise `false`.
     */
    public func refreshSource(_ sourceName: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let result = installManager.refreshSource(sourceName)
            continuation.resume(returning: result)
        }
    }

    /**
     Lists modules available from a remote source with optional category/language filters.
     - Parameters:
       - sourceName: Source/repository name to query.
       - category: Optional module-category filter.
       - language: Optional language-code filter.
     - Returns: Matching remote modules.
     */
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

    /**
     Lists configured remote sources exposed by the underlying installer.
     - Returns: Remote repository metadata rows.
     */
    public func remoteSources() -> [RemoteSource] {
        installManager.remoteSources()
    }
}
