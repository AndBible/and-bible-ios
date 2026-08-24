// ModuleInstallationContracts.swift - Shared Android-parity module installation contracts

import Foundation

/**
 Repository-scoped identity for one downloadable module.

 Android keys queue, progress, cancellation, and error state with `Book.repoIdentity`, whose value is
 `repository--initials`. Keeping the same two inputs as a typed value prevents modules with identical
 initials in different repositories from sharing mutable install state.

 Side effects:
 - none; values are immutable and safe to pass across tasks

 Failure modes:
 - none; repository and initials preserve the catalog values exactly
 */
public struct RemoteModuleIdentity: Hashable, Sendable, Codable, CustomStringConvertible {
    /// Repository name stored in Android's `SourceRepository` metadata.
    public let repository: String

    /// SWORD or custom-driver module initials.
    public let initials: String

    /**
     Android-compatible diagnostic spelling of the repository-scoped identity.

     - Returns: `repository--initials` without normalization; typed equality remains authoritative.
     - Side effects: None.
     - Failure modes: None.
     */
    public var rawValue: String { "\(repository)--\(initials)" }

    /**
     Human-readable representation used by diagnostics and accessibility identifiers.

     - Returns: The raw diagnostic spelling from `rawValue`.
     - Side effects: None.
     - Failure modes: None.
     */
    public var description: String { rawValue }

    /**
     Creates a repository-scoped module identity.

     - Parameters:
       - repository: Repository/source name attached to the catalog row.
       - initials: Module initials attached to the catalog row.
     - Side effects: none.
     - Failure modes: none; validation belongs to repository catalog parsing.
     */
    public init(repository: String, initials: String) {
        self.repository = repository
        self.initials = initials
    }

    /**
     Compares repository and module names with Java exact UTF-16 identity.

     - Parameters:
       - lhs: First repository-scoped module identity.
       - rhs: Second repository-scoped module identity.
     - Returns: `true` only when both repository and initials code units match exactly.
     - Side effects: None.
     - Failure modes: None.
     */
    public static func == (lhs: RemoteModuleIdentity, rhs: RemoteModuleIdentity) -> Bool {
        SwordJavaExactStringIdentity(lhs.repository) == SwordJavaExactStringIdentity(rhs.repository)
            && SwordJavaExactStringIdentity(lhs.initials) == SwordJavaExactStringIdentity(rhs.initials)
    }

    /**
     Hashes the same Java-exact fields used by equality.

     - Parameter hasher: Swift process-local hasher receiving exact repository and initials keys.
     - Side effects: Mutates only the supplied hasher.
     - Failure modes: None.
     */
    public func hash(into hasher: inout Hasher) {
        hasher.combine(SwordJavaExactStringIdentity(repository))
        hasher.combine(SwordJavaExactStringIdentity(initials))
    }
}

/**
 Adds Android's repository-scoped queue identity to the common remote module model.

 List rendering and mutable install state use this typed Java-exact identity instead of raw Swift
 strings, so repository/module NFC-NFD variants cannot share a row or task.
 */
public extension RemoteModuleInfo {
    /**
     Repository-scoped identity used by download, progress, cancellation, and retry state.

     - Returns: Java-exact source-name and module-initials identity for this catalog row.
     - Side effects: None.
     - Failure modes: None.
     */
    var installIdentity: RemoteModuleIdentity {
        RemoteModuleIdentity(repository: sourceName, initials: name)
    }
}

/**
 Durable phases emitted by remote and local module installers.

 Android exposes an install job rather than treating network byte count as the whole operation.
 These phases preserve that distinction for iOS, including work after the package reaches 100%.
 */
public enum ModuleInstallPhase: String, Sendable, Codable, CaseIterable {
    /// The request exists but has not started network or archive work.
    case queued

    /// Package bytes are being transferred into temporary storage.
    case downloading

    /// Validated package entries are being expanded into isolated staging storage.
    case extracting

    /// Staged files and configuration are being published with rollback protection.
    case committing

    /// Publish and cache invalidation both completed successfully.
    case complete
}

/**
 Immutable phase-aware module installation progress.

 `fraction` is local to the current phase and is intentionally optional. Servers that omit
 `Content-Length` therefore produce an indeterminate downloading state instead of a false zero or
 a progress bar that appears stalled. Completion is emitted only after publish and cache invalidation.

 Side effects:
 - none

 Failure modes:
 - invalid finite fractions are clamped to `0...1`; non-finite values become indeterminate
 */
public struct ModuleInstallProgress: Sendable, Equatable {
    /// Current installer phase.
    public let phase: ModuleInstallPhase

    /// Optional phase-local completion fraction.
    public let fraction: Double?

    /// Integer phase-local percentage for compact UI presentation.
    public var percent: Int? {
        fraction.map { Int(($0 * 100).rounded(.towardZero)) }
    }

    /**
     Whether an explicit user cancellation can still abort this install.

     The committing phase begins only after the canonical mutation coordinator closes its
     cancellation boundary. Completion is likewise terminal.
     */
    public var isCancellable: Bool {
        phase != .committing && phase != .complete
    }

    /**
     Creates one phase snapshot and normalizes its optional fraction.

     - Parameters:
       - phase: Current installer phase.
       - fraction: Optional phase-local completion in `0...1`.
     - Side effects: none.
     - Failure modes: Non-finite fractions are represented as `nil`.
     */
    public init(phase: ModuleInstallPhase, fraction: Double? = nil) {
        self.phase = phase
        if let fraction, fraction.isFinite {
            self.fraction = min(max(fraction, 0), 1)
        } else {
            self.fraction = nil
        }
    }
}

/**
 Result of checking local capacity before an install allocates package or staging data.

 Android refuses downloads when less than 50 MiB is available. iOS preserves that reserve and adds
 known package/extracted bytes so a large install does not pass the fixed gate and then fail halfway
 through transactional staging.
 */
public struct ModuleStorageRequirement: Sendable, Equatable {
    /// Capacity reported by the destination volume.
    public let availableBytes: Int64

    /// Capacity required for Android's reserve plus known additional install bytes.
    public let requiredBytes: Int64

    /// Whether the operation may start without violating the preflight requirement.
    public var isSatisfied: Bool { availableBytes >= requiredBytes }
}

/**
 Reads destination-volume capacity and applies the shared module-install storage policy.

 The provider is injectable so low-space behavior is deterministic in tests. Production uses the
 volume's important-usage capacity when available and falls back to ordinary available capacity.

 - Important: Capacity is a preflight signal, not a reservation. Installers still use staging and
   rollback because other processes can consume storage after this check.
 */
public struct ModuleStoragePreflight: Sendable {
    /// Android's `REQUIRED_MEGS_FOR_DOWNLOADS` expressed in bytes.
    public static let androidMinimumAvailableBytes: Int64 = 50 * 1_024 * 1_024

    /// Injected destination-volume capacity lookup.
    private let capacityProvider: @Sendable (URL) -> Int64?

    /**
     Creates a storage preflight service.

     - Parameter capacityProvider: Optional deterministic volume-capacity provider. The default
       reads Foundation volume resource values.
     - Side effects: none during initialization.
     - Failure modes: A provider may return `nil` when capacity is unavailable; checks then fail
       open because the platform cannot establish that storage is insufficient.
     */
    public init(capacityProvider: (@Sendable (URL) -> Int64?)? = nil) {
        self.capacityProvider = capacityProvider ?? { url in
            Self.availableCapacity(at: url)
        }
    }

    /**
     Calculates the current capacity requirement for one destination.

     - Parameters:
       - destinationURL: Existing or planned path on the target volume.
       - estimatedAdditionalBytes: Known package/extracted bytes that will be allocated in addition
         to Android's fixed reserve.
     - Returns: Requirement when volume capacity can be read; otherwise `nil`.
     - Side effects: Reads filesystem volume metadata.
     - Failure modes: Negative estimates are treated as zero; integer overflow saturates at
       `Int64.max` and therefore fails closed when capacity is known.
     */
    public func requirement(
        for destinationURL: URL,
        estimatedAdditionalBytes: Int64? = nil
    ) -> ModuleStorageRequirement? {
        guard let availableBytes = capacityProvider(destinationURL) else { return nil }
        let estimate = max(estimatedAdditionalBytes ?? 0, 0)
        let (sum, overflow) = Self.androidMinimumAvailableBytes.addingReportingOverflow(estimate)
        return ModuleStorageRequirement(
            availableBytes: max(availableBytes, 0),
            requiredBytes: overflow ? Int64.max : sum
        )
    }

    /**
     Reads usable capacity from the volume containing a destination URL.

     - Parameter url: Destination path whose containing volume should be inspected. The path may not
       exist yet during a first install, so the nearest existing ancestor supplies volume metadata.
     - Returns: Available bytes suitable for important usage, ordinary available bytes, or `nil`
       when Foundation cannot read either value.
     - Side effects: Reads URL volume metadata.
     - Failure modes: Resource-value errors return `nil` so callers do not block installs merely
       because a provider cannot report quota information.
     */
    private static func availableCapacity(at url: URL) -> Int64? {
        let fileManager = FileManager.default
        var volumeURL = url.standardizedFileURL
        while !fileManager.fileExists(atPath: volumeURL.path) {
            let parentURL = volumeURL.deletingLastPathComponent()
            guard parentURL.path != volumeURL.path else { return nil }
            volumeURL = parentURL
        }

        guard let values = try? volumeURL.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ]) else {
            return nil
        }
        let capacities = [
            values.volumeAvailableCapacityForImportantUsage,
            values.volumeAvailableCapacity.map(Int64.init),
        ].compactMap { $0 }
        return capacities.max()
    }
}

/**
 Read-only preflight result for a local Android-compatible SWORD ZIP.

 The result binds user-facing conflict context to the exact archive bytes. Installation repeats
 validation, hashing, and conflict detection before writing because both provider files and live
 destinations may change while a confirmation alert is visible.
 */
public struct LocalSwordZipInspection: Sendable, Equatable {
    /// Module initials discovered from direct `mods.d/*.conf` entries.
    public let moduleNames: [String]

    /// Existing destination files that require explicit overwrite consent.
    public let conflictingPaths: [String]

    /// Number of file entries that will be staged.
    public let installableEntryCount: Int

    /// Sum of advertised uncompressed bytes used by storage preflight.
    public let estimatedExpandedBytes: Int64

    /// Lowercase SHA-256 of the exact archive bytes inspected before confirmation.
    public let archiveSHA256: String

    /// Whether installation must receive explicit overwrite consent.
    public var requiresOverwriteConfirmation: Bool { !conflictingPaths.isEmpty }

    /// Exact immutable authorization callers may retain after presenting these conflicts.
    public var overwriteAuthorization: LocalSwordZipOverwriteAuthorization {
        LocalSwordZipOverwriteAuthorization(
            archiveSHA256: archiveSHA256,
            conflictingPaths: conflictingPaths
        )
    }

    /**
     Creates an immutable local-package inspection result.

     - Parameters:
       - moduleNames: Module initials found in config filenames.
       - conflictingPaths: Existing relative destination paths.
       - installableEntryCount: Count of files accepted by Android's root-layout contract.
       - estimatedExpandedBytes: Sum of uncompressed entry sizes.
       - archiveSHA256: Lowercase SHA-256 of the inspected archive bytes.
     - Side effects: none.
     - Failure modes: none; archive validation happens before construction.
     */
    public init(
        moduleNames: [String],
        conflictingPaths: [String],
        installableEntryCount: Int,
        estimatedExpandedBytes: Int64,
        archiveSHA256: String
    ) {
        self.moduleNames = moduleNames
        self.conflictingPaths = conflictingPaths
        self.installableEntryCount = installableEntryCount
        self.estimatedExpandedBytes = estimatedExpandedBytes
        self.archiveSHA256 = archiveSHA256
    }
}

/**
 Immutable overwrite consent produced from one read-only archive inspection.

 The archive digest prevents a provider from swapping the selected file after confirmation. The
 exact path set limits publication to conflicts shown in the prompt; conflicts that appear later
 are rejected and require a fresh preflight rather than being covered by a broad boolean.
 */
public struct LocalSwordZipOverwriteAuthorization: Sendable, Equatable {
    /// Lowercase SHA-256 of the archive whose conflicts the user approved.
    public let archiveSHA256: String

    /// Canonical root-relative destination paths shown in the confirmation prompt.
    public let conflictingPaths: [String]

    /**
     Creates archive-bound overwrite consent.

     - Parameters:
       - archiveSHA256: Lowercase SHA-256 of the preflighted archive.
       - conflictingPaths: Exact canonical destinations shown to the user.
     - Side effects: none.
     - Failure modes: This initializer cannot fail; installers reject mismatched digests or paths.
     */
    public init(archiveSHA256: String, conflictingPaths: [String]) {
        self.archiveSHA256 = archiveSHA256
        self.conflictingPaths = Array(Set(conflictingPaths)).sorted()
    }
}

/**
 Explicit overwrite policy for local SWORD ZIP installation.

 The default reject policy makes every non-interactive entry point fail safely. UI surfaces may
 retain archive-bound consent only after presenting Android's conflicting-file list. Publication
 rejects a changed archive or any live conflict outside that approved set.
 */
public enum LocalSwordZipOverwritePolicy: Sendable, Equatable {
    /// Reject any archive whose destination files already exist.
    case reject

    /// Replace only the exact conflicts approved for the exact preflighted archive.
    case replaceExisting(LocalSwordZipOverwriteAuthorization)

    /// Archive-bound authorization carried by replacement policy, or `nil` for strict rejection.
    public var authorization: LocalSwordZipOverwriteAuthorization? {
        guard case .replaceExisting(let authorization) = self else { return nil }
        return authorization
    }
}
