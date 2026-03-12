// RemoteSyncSynchronizationServiceFactory.swift — Backend-aware synchronization coordinator builder

import Foundation

/**
 Errors raised while constructing a backend-specific remote synchronization coordinator.

 `RemoteSyncLifecycleService` and `SyncSettingsView` both need a single place that turns persisted
 backend selection plus local credentials/session state into a concrete
 `RemoteSyncSynchronizationService`. These errors describe the small set of reasons that operation
 can fail before any remote I/O starts.
 */
public enum RemoteSyncSynchronizationServiceFactoryError: Error, Equatable {
    /// The selected backend is not a remote backend that uses `RemoteSyncSynchronizationService`.
    case unsupportedBackend(RemoteSyncBackend)

    /// NextCloud/WebDAV settings are missing required non-secret fields.
    case invalidWebDAVConfiguration

    /// NextCloud/WebDAV settings do not currently have a usable password.
    case missingWebDAVPassword

    /// Google Drive requires a configured auth/token provider before sync can run.
    case googleDriveAuthenticationRequired
}

extension RemoteSyncSynchronizationServiceFactoryError: LocalizedError {
    /**
     User-visible localized description for one factory failure.

     - Returns: Localized message suitable for settings and lifecycle error surfaces.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    public var errorDescription: String? {
        switch self {
        case .unsupportedBackend:
            return String(localized: "sync_error")
        case .invalidWebDAVConfiguration:
            return String(localized: "invalid_url_message")
        case .missingWebDAVPassword:
            return String(localized: "sign_in_failed")
        case .googleDriveAuthenticationRequired:
            return String(localized: "google_drive_not_signed_in")
        }
    }
}

/**
 Builds backend-specific `RemoteSyncSynchronizationService` instances from persisted settings.

 Data dependencies:
 - `RemoteSyncSettingsStore` provides backend selection, WebDAV settings, and the stable device ID
 - `GoogleDriveAccessTokenProvider`, when supplied, yields OAuth access tokens for the Google Drive
   backend

 Side effects:
 - may generate and persist a stable remote device identifier on first use through
   `RemoteSyncSettingsStore.deviceIdentifier()`
 - does not perform any remote I/O; it only validates local configuration and instantiates backend
   adapters

 Failure modes:
 - throws `RemoteSyncSynchronizationServiceFactoryError.invalidWebDAVConfiguration` when required
   NextCloud/WebDAV fields are missing or malformed
 - throws `RemoteSyncSynchronizationServiceFactoryError.missingWebDAVPassword` when the WebDAV
   password is blank
 - throws `RemoteSyncSynchronizationServiceFactoryError.googleDriveAuthenticationRequired` when the
   selected backend is Google Drive but no token provider was supplied
 */
public final class RemoteSyncSynchronizationServiceFactory {
    private let bundleIdentifier: String
    private let googleDriveAccessTokenProvider: GoogleDriveAccessTokenProvider?

    /**
     Creates a synchronization-service factory.

     - Parameters:
       - bundleIdentifier: App bundle identifier used to build Android-style sync folder names.
       - googleDriveAccessTokenProvider: Optional OAuth access-token provider used when Google Drive
         is the selected backend.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        bundleIdentifier: String,
        googleDriveAccessTokenProvider: GoogleDriveAccessTokenProvider? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.googleDriveAccessTokenProvider = googleDriveAccessTokenProvider
    }

    /**
     Builds a backend-specific remote synchronization coordinator from persisted settings.

     - Parameter remoteSettingsStore: Persisted remote-sync settings for the current model context.
     - Returns: Configured backend-specific synchronization coordinator.
     - Side effects:
       - may generate and persist a stable device identifier through `remoteSettingsStore`
     - Failure modes:
       - throws `RemoteSyncSynchronizationServiceFactoryError` for local configuration issues
       - re-throws `WebDAVClientError.invalidURL` when the stored NextCloud server URL is malformed
     */
    public func makeSynchronizationService(
        using remoteSettingsStore: RemoteSyncSettingsStore
    ) throws -> RemoteSyncSynchronizationService {
        let adapter = try makeAdapter(using: remoteSettingsStore)
        return RemoteSyncSynchronizationService(
            adapter: adapter,
            bundleIdentifier: bundleIdentifier,
            deviceIdentifier: remoteSettingsStore.deviceIdentifier()
        )
    }

    /**
     Builds the concrete backend adapter selected in local settings.

     - Parameter remoteSettingsStore: Persisted remote-sync settings for the current model context.
     - Returns: Concrete backend adapter selected in local settings.
     - Side effects:
       - reads local credentials or auth state from `RemoteSyncSettingsStore`
     - Failure modes:
       - throws `RemoteSyncSynchronizationServiceFactoryError` for missing local configuration
       - re-throws `WebDAVClientError.invalidURL` when the stored NextCloud server URL is malformed
     */
    public func makeAdapter(
        using remoteSettingsStore: RemoteSyncSettingsStore
    ) throws -> any RemoteSyncAdapting {
        switch remoteSettingsStore.selectedBackend {
        case .iCloud:
            throw RemoteSyncSynchronizationServiceFactoryError.unsupportedBackend(.iCloud)
        case .nextCloud:
            guard let configuration = remoteSettingsStore.loadWebDAVConfiguration() else {
                throw RemoteSyncSynchronizationServiceFactoryError.invalidWebDAVConfiguration
            }

            guard let password = remoteSettingsStore.webDAVPassword()?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !password.isEmpty else {
                throw RemoteSyncSynchronizationServiceFactoryError.missingWebDAVPassword
            }

            return try NextCloudSyncAdapter(configuration: configuration, password: password)
        case .googleDrive:
            guard let googleDriveAccessTokenProvider else {
                throw RemoteSyncSynchronizationServiceFactoryError.googleDriveAuthenticationRequired
            }
            return GoogleDriveSyncAdapter(accessTokenProvider: googleDriveAccessTokenProvider)
        }
    }
}
