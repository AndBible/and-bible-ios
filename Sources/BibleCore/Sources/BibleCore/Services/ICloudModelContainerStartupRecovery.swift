import Foundation

/**
 Loads the startup model container while treating iCloud/CloudKit activation as recoverable.

 SwiftData's CloudKit integration validates the full model before the app can render any UI. When
 a persisted iCloud toggle points startup at a CloudKit-backed container that cannot load, the app
 must not trap before users can recover. This helper preserves the requested CloudKit path first,
 then retries the same store locally and clears the bootstrap toggle only after local startup has
 succeeded.
 */
public enum ICloudModelContainerStartupRecovery {
    /**
     Result of startup container loading.

     - Parameter Container: Concrete container type supplied by the app shell.
     - Note: The type is generic so the retry and preference contract can be unit-tested without
       constructing real SwiftData or CloudKit containers.
     */
    public struct Result<Container> {
        /// Container returned by the successful startup path.
        public let container: Container

        /// Effective iCloud mode for the current runtime after any fallback.
        public let effectiveICloudEnabled: Bool

        /// Whether startup recovered from a failed CloudKit-backed load by opening locally.
        public let didRecoverFromCloudKitFailure: Bool

        /// Original CloudKit load error preserved for diagnostics when fallback succeeds.
        public let cloudKitLoadErrorDescription: String?
    }

    /**
     Loads the requested startup container and falls back to local storage after CloudKit failure.

     - Parameters:
       - iCloudEnabled: Persisted bootstrap preference read before the app has a SwiftData context.
       - defaults: Defaults store that owns `syncEnabledKey`.
       - syncEnabledKey: Defaults key used by the app's iCloud toggle.
       - loadCloudKitContainer: Closure that attempts the CloudKit-backed container.
       - loadLocalContainer: Closure that attempts the local-only container.
     - Returns: Container load result and the effective runtime iCloud mode.
     - Side effects:
       - calls `loadCloudKitContainer` before `loadLocalContainer` when `iCloudEnabled` is true
       - writes `false` to `syncEnabledKey` only when CloudKit failed and local fallback succeeded
     - Failure modes:
       - rethrows local container failures when iCloud is disabled
       - rethrows local fallback failures when both CloudKit and local startup fail
     */
    public static func loadContainer<Container>(
        iCloudEnabled: Bool,
        defaults: UserDefaults = .standard,
        syncEnabledKey: String,
        loadCloudKitContainer: () throws -> Container,
        loadLocalContainer: () throws -> Container
    ) throws -> Result<Container> {
        guard iCloudEnabled else {
            return Result(
                container: try loadLocalContainer(),
                effectiveICloudEnabled: false,
                didRecoverFromCloudKitFailure: false,
                cloudKitLoadErrorDescription: nil
            )
        }

        do {
            return Result(
                container: try loadCloudKitContainer(),
                effectiveICloudEnabled: true,
                didRecoverFromCloudKitFailure: false,
                cloudKitLoadErrorDescription: nil
            )
        } catch {
            let cloudKitError = error
            let container = try loadLocalContainer()
            defaults.set(false, forKey: syncEnabledKey)
            return Result(
                container: container,
                effectiveICloudEnabled: false,
                didRecoverFromCloudKitFailure: true,
                cloudKitLoadErrorDescription: String(describing: cloudKitError)
            )
        }
    }
}
