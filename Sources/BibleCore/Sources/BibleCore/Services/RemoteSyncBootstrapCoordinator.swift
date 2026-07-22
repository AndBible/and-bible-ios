// RemoteSyncBootstrapCoordinator.swift — Android-aligned category bootstrap flow for WebDAV sync

import Foundation

/** Errors raised when a remote body exceeds a caller-owned streaming limit. */
public enum RemoteSyncBoundedDownloadError: Error, Equatable {
    /// Declared or observed response bytes exceed the accepted ceiling.
    case payloadTooLarge(Int64)
}

/**
 Abstraction for remote-sync backends that support Android-style folder bootstrap operations.

 The current iOS WebDAV work only has one concrete implementation, `NextCloudSyncAdapter`, but the
 bootstrap flow is easier to test and evolve when the coordinator depends on a narrow protocol
 instead of a concrete transport actor.
 */
public protocol RemoteSyncAdapting: Sendable {
    /**
     Lists remote files or folders that match the supplied filter criteria.

     - Parameters:
       - parentIDs: Optional parent folder identifiers to search under. `nil` uses the adapter's
         default base scope.
       - name: Optional exact filename or folder-name filter.
       - mimeType: Optional Android-compatible MIME type filter.
       - modifiedAtLeast: Optional lower-bound timestamp for incremental listing.
     - Returns: Matching remote file descriptors.
     - Side effects: performs remote backend requests.
     - Throws: Backend-specific transport or authentication errors.
     */
    func listFiles(
        parentIDs: [String]?,
        name: String?,
        mimeType: String?,
        modifiedAtLeast: Date?
    ) async throws -> [RemoteSyncFile]

    /**
     Creates a remote folder.

     - Parameters:
       - name: Folder name to create.
       - parentID: Optional parent folder identifier. `nil` uses the adapter's default base scope.
     - Returns: Metadata for the created folder.
     - Side effects: performs a remote folder-creation request.
     - Throws: Backend-specific transport or validation errors.
     */
    func createNewFolder(name: String, parentID: String?) async throws -> RemoteSyncFile

    /**
     Downloads one remote file payload into memory.

     - Parameter id: Backend-specific file identifier returned by prior adapter calls.
     - Returns: Raw remote file payload bytes.
     - Side effects: performs a remote file-download request.
     - Throws: Backend-specific transport errors.
     */
    func download(id: String) async throws -> Data

    /**
     Streams one remote payload into a bounded local file.

     - Parameters:
       - id: Backend-specific file identifier.
       - destinationURL: Unique local destination file.
       - maximumByteCount: Maximum accepted response bytes.
     - Returns: Exact bytes written.
     - Side effects: Performs remote I/O and creates `destinationURL`.
     - Throws: Transport, filesystem, or `payloadTooLarge` failures; partial files are removed.
     */
    func download(
        id: String,
        to destinationURL: URL,
        maximumByteCount: Int
    ) async throws -> Int64

    /**
     Uploads one local file into a remote folder.

     - Parameters:
       - name: Destination file name to create remotely.
       - fileURL: Local file URL whose contents should be uploaded.
       - parentID: Remote parent folder identifier that should receive the file.
       - contentType: MIME type sent with the upload request.
     - Returns: Metadata for the uploaded remote file.
     - Side effects: performs a remote file-upload request.
     - Throws: Backend-specific transport or local-file read errors.
     */
    func upload(
        name: String,
        fileURL: URL,
        parentID: String,
        contentType: String
    ) async throws -> RemoteSyncFile

    /**
     Deletes a remote file or folder tree.

     - Parameter id: Backend-specific identifier to delete.
     - Side effects: performs a remote delete request.
     - Throws: Backend-specific transport errors.
     */
    func delete(id: String) async throws

    /**
     Checks whether the stored secret marker still proves ownership of a sync folder.

     - Parameters:
       - syncFolderID: Remote identifier for the category's global sync folder.
       - secretFileName: Stored secret marker filename.
     - Returns: `true` when the marker still exists in the remote folder.
     - Side effects: performs a remote metadata lookup.
     - Throws: Backend-specific transport errors.
     */
    func isSyncFolderKnown(syncFolderID: String, secretFileName: String) async throws -> Bool

    /**
     Uploads a fresh secret marker file to prove ownership of a sync folder.

     - Parameters:
       - syncFolderID: Remote identifier for the category's global sync folder.
       - deviceIdentifier: Stable device identifier used in the marker filename prefix.
     - Returns: Newly created secret marker filename.
     - Side effects: uploads an empty remote marker file.
     - Throws: Backend-specific transport errors.
     */
    func makeSyncFolderKnown(syncFolderID: String, deviceIdentifier: String) async throws -> String
}

public extension RemoteSyncAdapting {
    /**
     Compatibility implementation for deterministic adapters that expose only in-memory payloads.

     Production WebDAV overrides this method with response-byte streaming. The default validates
     the complete mock payload before its first filesystem write and removes partial destinations.

     - Parameters:
       - id: Backend-specific file identifier.
       - destinationURL: Unique local destination file.
       - maximumByteCount: Maximum accepted payload bytes.
     - Returns: Exact bytes written.
     - Side effects: Downloads through `download(id:)` and writes one local file.
     - Throws: Existing adapter errors, filesystem errors, or `payloadTooLarge`.
     */
    func download(
        id: String,
        to destinationURL: URL,
        maximumByteCount: Int
    ) async throws -> Int64 {
        let data = try await download(id: id)
        guard data.count <= maximumByteCount else {
            throw RemoteSyncBoundedDownloadError.payloadTooLarge(Int64(data.count))
        }
        do {
            try data.write(to: destinationURL, options: [.atomic])
            return Int64(data.count)
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
    }
}

extension NextCloudSyncAdapter: RemoteSyncAdapting {}

/**
 Metadata describing a remotely discovered category folder that requires a user decision.

 Android prompts when it finds a remote sync folder for a category but does not yet have a valid
 local ownership marker for that folder. The iOS WebDAV flow uses the same decision point so the
 UI can offer "copy from cloud" versus "copy from this device" behavior later.
 */
public struct RemoteSyncBootstrapCandidate: Sendable, Equatable {
    /// Logical sync category being bootstrapped.
    public let category: RemoteSyncCategory

    /// Android-style top-level sync folder name for the category.
    public let syncFolderName: String

    /// Remote identifier for the discovered category folder.
    public let remoteFolderID: String

    /**
     Creates a remote-adoption candidate payload.

     - Parameters:
       - category: Logical sync category being bootstrapped.
       - syncFolderName: Android-style top-level sync folder name for the category.
       - remoteFolderID: Remote identifier for the discovered category folder.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(category: RemoteSyncCategory, syncFolderName: String, remoteFolderID: String) {
        self.category = category
        self.syncFolderName = syncFolderName
        self.remoteFolderID = remoteFolderID
    }
}

/**
 Metadata describing a category that needs a brand-new remote sync folder.
 */
public struct RemoteSyncBootstrapCreation: Sendable, Equatable {
    /// Logical sync category being bootstrapped.
    public let category: RemoteSyncCategory

    /// Android-style top-level sync folder name that should be created remotely.
    public let syncFolderName: String

    /**
     Creates a remote-creation payload.

     - Parameters:
       - category: Logical sync category being bootstrapped.
       - syncFolderName: Android-style top-level sync folder name that should be created remotely.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(category: RemoteSyncCategory, syncFolderName: String) {
        self.category = category
        self.syncFolderName = syncFolderName
    }
}

/**
 Errors raised when persisted bootstrap lifecycle metadata cannot be interpreted safely.
 */
public enum RemoteSyncBootstrapError: Error, Equatable {
    /// A newer or corrupted persisted phase cannot be treated as ready by this build.
    case unsupportedPersistedPhase(String)
}

/**
 Result of inspecting one category's remote-sync bootstrap state.

 `ready` means the category has a valid known sync folder, a local device folder, and a completed
 initial baseline exchange. The other cases map directly to Android's initial bootstrap branches:
 - `requiresRemoteAdoption`: a same-named remote folder exists and the caller must decide whether
   to adopt it
 - `requiresRemoteCreation`: no reusable remote folder exists, so the caller can create a fresh
   category folder immediately
 */
public enum RemoteSyncBootstrapStatus: Sendable, Equatable {
    /// Category bootstrap is complete and local state is ready for future patch sync.
    case ready(RemoteSyncBootstrapState)

    /// Remote setup exists, but the adopted folder's initial backup still needs local restoration.
    case requiresInitialRestore(RemoteSyncBootstrapState)

    /// Remote setup exists, but this device's local baseline still needs its initial upload.
    case requiresInitialUpload(RemoteSyncBootstrapState)

    /// A matching remote folder exists but is not yet owned locally.
    case requiresRemoteAdoption(RemoteSyncBootstrapCandidate)

    /// No reusable remote folder exists and a new one should be created.
    case requiresRemoteCreation(RemoteSyncBootstrapCreation)
}

/**
 Coordinates Android-aligned remote bootstrap decisions for one sync backend.

 This coordinator mirrors the non-UI portions of Android's `CloudSync.initializeSync()` flow:
 - validate any locally stored sync-folder ownership marker
 - clear stale bootstrap state when the marker is missing or incomplete
 - discover same-named remote folders that may need an adopt-vs-create decision
 - persist the chosen sync folder, device folder, and secret marker after adoption or creation

 Data dependencies:
 - `RemoteSyncAdapting` performs remote listing, folder creation, deletion, and secret-marker work
 - `RemoteSyncStateStore` persists Android-aligned bootstrap metadata locally

 Side effects:
 - inspection may clear stale bootstrap keys in `RemoteSyncStateStore`
 - adoption and creation upload secret markers, create remote device folders, and persist a pending
   initial-baseline phase
 - create-with-replacement can delete a previously discovered remote folder before recreating it

 Failure modes:
 - rethrows backend transport errors from the adapter
 - bootstrap-state transaction failures are rethrown after rollback

 Concurrency:
 - this type is intentionally not `Sendable`; callers must respect the thread/actor confinement of
   the `SettingsStore` and SwiftData context captured by `RemoteSyncStateStore`
 */
public final class RemoteSyncBootstrapCoordinator {
    private let adapter: any RemoteSyncAdapting
    private let stateStore: RemoteSyncStateStore
    private let bundleIdentifier: String
    private let deviceIdentifier: String

    /**
     Creates a coordinator for one remote backend and one local settings context.

     - Parameters:
       - adapter: Remote backend adapter that performs Android-style folder bootstrap operations.
       - stateStore: Local persistence store for category bootstrap metadata.
       - bundleIdentifier: App bundle identifier used to build Android-style sync folder names.
       - deviceIdentifier: Stable per-device identifier used for device folder names and markers.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        adapter: any RemoteSyncAdapting,
        stateStore: RemoteSyncStateStore,
        bundleIdentifier: String,
        deviceIdentifier: String
    ) {
        self.adapter = adapter
        self.stateStore = stateStore
        self.bundleIdentifier = bundleIdentifier
        self.deviceIdentifier = deviceIdentifier
    }

    /**
     Inspects one category and returns the next bootstrap action Android would require.

     The coordinator first validates any locally stored sync folder and secret marker. If that
     ownership proof is still valid, the persisted initial-baseline phase determines whether the
     category is ready or must resume a restore/upload. Any missing device folder is repaired while
     retaining that phase. Otherwise stale bootstrap keys are cleared, the backend is queried for a
     same-named remote folder, and the result becomes either an adopt decision or fresh-create path.

     - Parameter category: Logical sync category to inspect.
     - Returns: Ready state, resumable initial transfer, remote-adoption candidate, or remote-creation requirement.
     - Side effects:
       - may clear stale bootstrap keys
       - may create and persist a replacement device folder when the sync folder is still owned
         but the local `deviceFolderID` is missing
       - performs remote marker validation and remote folder discovery requests
     - Failure modes:
       - rethrows backend errors from secret-marker validation, remote listing, or device-folder repair
       - throws `RemoteSyncBootstrapError.unsupportedPersistedPhase` for unknown lifecycle metadata
     */
    public func inspect(_ category: RemoteSyncCategory) async throws -> RemoteSyncBootstrapStatus {
        let syncFolderName = category.syncFolderName(bundleIdentifier: bundleIdentifier)
        let bootstrapState = stateStore.bootstrapState(for: category)

        if let knownState = try await validatedStateIfKnown(bootstrapState, category: category) {
            switch knownState.phase {
            case .ready:
                return .ready(knownState)
            case .awaitingRemoteInitialRestore:
                return .requiresInitialRestore(knownState)
            case .awaitingLocalInitialUpload:
                return .requiresInitialUpload(knownState)
            case .unsupported(let value):
                throw RemoteSyncBootstrapError.unsupportedPersistedPhase(value)
            }
        }

        let discoveredRemoteFolder = try await adapter.listFiles(
            parentIDs: nil,
            name: syncFolderName,
            mimeType: nil,
            modifiedAtLeast: nil
        ).first

        if let discoveredRemoteFolder {
            return .requiresRemoteAdoption(
                RemoteSyncBootstrapCandidate(
                    category: category,
                    syncFolderName: syncFolderName,
                    remoteFolderID: discoveredRemoteFolder.id
                )
            )
        }

        return .requiresRemoteCreation(
            RemoteSyncBootstrapCreation(
                category: category,
                syncFolderName: syncFolderName
            )
        )
    }

    /**
     Marks a discovered remote folder as owned and records that its initial backup awaits restore.

     - Parameters:
       - category: Logical sync category being adopted.
       - remoteFolderID: Remote identifier of the existing category folder to adopt.
     Existing pending adoption state for the same valid folder is reused so retries do not create a
     second marker or device folder.

     - Returns: Persisted bootstrap state whose initial restore remains pending.
     - Side effects:
       - uploads a new secret marker file into the remote folder
       - creates the per-device patch folder beneath the adopted sync folder
       - atomically persists the resulting identifiers and pending-restore phase locally
     - Failure modes:
       - rethrows backend errors from secret-marker upload or device-folder creation
     */
    public func adoptRemoteFolder(
        for category: RemoteSyncCategory,
        remoteFolderID: String
    ) async throws -> RemoteSyncBootstrapState {
        let existingState = stateStore.bootstrapState(for: category)
        if existingState.syncFolderID == remoteFolderID,
           existingState.phase == .awaitingRemoteInitialRestore,
           let reusableState = try await validatedStateIfKnown(existingState, category: category) {
            return reusableState
        }
        return try await persistBootstrapState(
            category: category,
            syncFolderID: remoteFolderID,
            phase: .awaitingRemoteInitialRestore
        )
    }

    /**
     Creates a remote category folder and records that its local initial baseline awaits upload.

     Existing pending local-upload state is reused so a retry after upload failure does not create
     or delete another remote folder tree.

     - Parameters:
       - category: Logical sync category being created.
       - replacingRemoteFolderID: Optional previously discovered remote folder to delete first,
         matching Android's "copy this device to the cloud" replacement path.
     - Returns: Persisted bootstrap state whose local initial upload remains pending.
     - Side effects:
       - may delete a previously discovered remote folder tree
       - creates a new top-level category folder and a per-device patch folder
       - uploads a new secret marker file into the created category folder
       - atomically persists the resulting identifiers and pending-upload phase locally
     - Failure modes:
       - rethrows backend errors from delete, folder creation, or marker upload operations
     */
    public func createRemoteFolder(
        for category: RemoteSyncCategory,
        replacingRemoteFolderID: String? = nil
    ) async throws -> RemoteSyncBootstrapState {
        let existingState = stateStore.bootstrapState(for: category)
        if existingState.phase == .awaitingLocalInitialUpload,
           let reusableState = try await validatedStateIfKnown(existingState, category: category) {
            return reusableState
        }

        if let replacingRemoteFolderID {
            try await adapter.delete(id: replacingRemoteFolderID)
        }

        let syncFolderName = category.syncFolderName(bundleIdentifier: bundleIdentifier)
        let syncFolder = try await adapter.createNewFolder(name: syncFolderName, parentID: nil)
        return try await persistBootstrapState(
            category: category,
            syncFolderID: syncFolder.id,
            phase: .awaitingLocalInitialUpload
        )
    }

    /**
     Validates locally stored bootstrap state and repairs missing device-folder metadata.

     - Parameters:
       - bootstrapState: Locally persisted bootstrap state to validate.
       - category: Logical sync category being inspected.
     - Returns: Valid bootstrap state with its original lifecycle phase; otherwise `nil`.
     - Side effects:
       - may clear stale bootstrap state when the stored sync folder cannot be proven as owned
       - may create and persist a missing device folder when the sync folder remains valid
       - performs remote ownership validation requests
     - Failure modes:
       - rethrows backend errors from marker validation or device-folder creation
     */
    private func validatedStateIfKnown(
        _ bootstrapState: RemoteSyncBootstrapState,
        category: RemoteSyncCategory
    ) async throws -> RemoteSyncBootstrapState? {
        guard let syncFolderID = bootstrapState.syncFolderID,
              !syncFolderID.isEmpty,
              let secretFileName = bootstrapState.secretFileName,
              !secretFileName.isEmpty else {
            if bootstrapState.syncFolderID != nil
                || bootstrapState.deviceFolderID != nil
                || bootstrapState.secretFileName != nil
                || bootstrapState.phase != .ready {
                try stateStore.setBootstrapStateAtomically(RemoteSyncBootstrapState(), for: category)
            }
            return nil
        }

        let isKnown = try await adapter.isSyncFolderKnown(
            syncFolderID: syncFolderID,
            secretFileName: secretFileName
        )
        guard isKnown else {
            try stateStore.setBootstrapStateAtomically(RemoteSyncBootstrapState(), for: category)
            return nil
        }

        if let deviceFolderID = bootstrapState.deviceFolderID, !deviceFolderID.isEmpty {
            return bootstrapState
        }

        return try await persistBootstrapState(
            category: category,
            syncFolderID: syncFolderID,
            secretFileName: secretFileName,
            phase: bootstrapState.phase
        )
    }

    /**
     Creates and persists the local bootstrap state for a known sync folder.

     - Parameters:
       - category: Logical sync category being updated.
       - syncFolderID: Remote identifier for the category's global sync folder.
       - secretFileName: Optional existing secret marker filename. When absent, a fresh marker is uploaded.
       - phase: Initial-baseline lifecycle phase to persist with the remote identifiers.
     - Returns: Bootstrap state containing sync folder, device folder, marker, and lifecycle phase.
     - Side effects:
       - may upload a new secret marker file
       - creates the per-device patch folder beneath the sync folder
       - atomically persists the resulting bootstrap identifiers and phase locally
     - Failure modes:
       - rethrows backend errors from marker upload or device-folder creation
     */
    private func persistBootstrapState(
        category: RemoteSyncCategory,
        syncFolderID: String,
        secretFileName: String? = nil,
        phase: RemoteSyncBootstrapPhase
    ) async throws -> RemoteSyncBootstrapState {
        let resolvedSecretFileName: String
        if let secretFileName, !secretFileName.isEmpty {
            resolvedSecretFileName = secretFileName
        } else {
            resolvedSecretFileName = try await adapter.makeSyncFolderKnown(
                syncFolderID: syncFolderID,
                deviceIdentifier: deviceIdentifier
            )
        }

        let deviceFolder = try await adapter.createNewFolder(
            name: deviceIdentifier,
            parentID: syncFolderID
        )
        let state = RemoteSyncBootstrapState(
            syncFolderID: syncFolderID,
            deviceFolderID: deviceFolder.id,
            secretFileName: resolvedSecretFileName,
            phase: phase
        )
        try stateStore.setBootstrapStateForNewDestinationAtomically(state, for: category)
        return state
    }
}
