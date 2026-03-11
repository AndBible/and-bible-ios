// RemoteSyncPatchDiscoveryService.swift — Remote initial backup and patch discovery

import Foundation

/**
 Errors emitted while discovering remote initial backups or patch files.
 */
public enum RemoteSyncPatchDiscoveryError: Error, Equatable {
    /// The category has no known sync folder, so remote discovery cannot proceed.
    case missingSyncFolderID

    /// A remote patch requires the supplied newer local schema version to be supported first.
    case incompatiblePatchVersion(Int)

    /// One or more earlier patches are missing, so incremental application would be unsafe.
    case patchFilesSkipped
}

/**
 Metadata for one remote patch file that is pending local application.
 */
public struct RemoteSyncDiscoveredPatch: Sendable, Equatable {
    /// Source device folder name that owns the patch stream.
    public let sourceDevice: String

    /// Monotonic patch number within the source device folder.
    public let patchNumber: Int64

    /// Schema version encoded into the remote patch filename.
    public let schemaVersion: Int

    /// Remote file descriptor for the patch archive.
    public let file: RemoteSyncFile

    /**
     Creates one discovered remote patch descriptor.

     - Parameters:
       - sourceDevice: Source device folder name that owns the patch stream.
       - patchNumber: Monotonic patch number within the source device folder.
       - schemaVersion: Schema version encoded into the patch filename.
       - file: Remote file descriptor for the patch archive.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(sourceDevice: String, patchNumber: Int64, schemaVersion: Int, file: RemoteSyncFile) {
        self.sourceDevice = sourceDevice
        self.patchNumber = patchNumber
        self.schemaVersion = schemaVersion
        self.file = file
    }
}

/**
 Result of scanning a remote category for device folders and pending patch files.
 */
public struct RemoteSyncPatchDiscoveryResult: Sendable, Equatable {
    /// Remote device folders discovered beneath the category sync folder.
    public let deviceFolders: [RemoteSyncFile]

    /// Pending patch files sorted by remote timestamp.
    public let pendingPatches: [RemoteSyncDiscoveredPatch]

    /**
     Creates a patch-discovery result payload.

     - Parameters:
       - deviceFolders: Remote device folders discovered beneath the category sync folder.
       - pendingPatches: Pending patch files sorted by remote timestamp.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(deviceFolders: [RemoteSyncFile], pendingPatches: [RemoteSyncDiscoveredPatch]) {
        self.deviceFolders = deviceFolders
        self.pendingPatches = pendingPatches
    }
}

/**
 Discovers Android-style initial backups and incremental patch files for a sync category.

 This service mirrors Android's remote listing logic from `CloudSync.downloadAndApplyNewPatches()`
 and its initial-backup lookup:
 - list device folders under the category sync folder
 - use `lastSynchronized` as the incremental lower bound when available
 - parse patch filenames as `<patchNumber>.<schemaVersion>.sqlite3.gz`
 - skip already applied patches recorded in `RemoteSyncPatchStatusStore`
 - fail fast when earlier patches are missing or when a newer schema version is encountered

 Data dependencies:
 - `RemoteSyncAdapting` performs remote folder and file listings
 - `RemoteSyncPatchStatusStore` provides local applied-patch bookkeeping per category

 Side effects:
 - performs remote discovery requests against the active sync backend

 Failure modes:
 - throws `RemoteSyncPatchDiscoveryError.missingSyncFolderID` when bootstrap state is incomplete
 - throws `RemoteSyncPatchDiscoveryError.incompatiblePatchVersion` when a remote patch requires a
   newer local schema version
 - throws `RemoteSyncPatchDiscoveryError.patchFilesSkipped` when incremental discovery proves a
   gap in the patch sequence for a device folder
 - rethrows backend transport errors from the adapter
 */
public final class RemoteSyncPatchDiscoveryService {
    /// Android-compatible filename used for full initial backups.
    public static let initialBackupFilename = "initial.sqlite3.gz"

    private let adapter: any RemoteSyncAdapting
    private let statusStore: RemoteSyncPatchStatusStore

    private static let patchFilePattern = try! NSRegularExpression(
        pattern: #"^(\d+)\.((\d+)\.)?sqlite3\.gz$"#,
        options: []
    )

    /**
     Creates a patch-discovery service for one remote backend.

     - Parameters:
       - adapter: Remote backend adapter used for listing folders and files.
       - statusStore: Local applied-patch bookkeeping store.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(adapter: any RemoteSyncAdapting, statusStore: RemoteSyncPatchStatusStore) {
        self.adapter = adapter
        self.statusStore = statusStore
    }

    /**
     Finds the category's initial backup archive when one exists remotely.

     - Parameter syncFolderID: Remote identifier for the category's global sync folder.
     - Returns: Remote file descriptor for `initial.sqlite3.gz`, or `nil` when absent.
     - Side effects: performs one remote listing request.
     - Failure modes: rethrows backend transport errors from the adapter.
     */
    public func findInitialBackup(syncFolderID: String) async throws -> RemoteSyncFile? {
        try await adapter.listFiles(
            parentIDs: [syncFolderID],
            name: Self.initialBackupFilename,
            mimeType: nil,
            modifiedAtLeast: nil
        ).first
    }

    /**
     Discovers pending remote patches for one category.

     - Parameters:
       - category: Logical sync category being scanned.
       - bootstrapState: Locally persisted bootstrap state for the category.
       - progressState: Locally persisted patch progress metadata for the category.
       - currentSchemaVersion: Current local schema version for the category database.
     - Returns: Discovered device folders and pending patch files sorted by remote timestamp.
     - Side effects:
       - performs remote folder and patch listings against the backend
     - Failure modes:
       - throws `RemoteSyncPatchDiscoveryError.missingSyncFolderID` when bootstrap state is incomplete
       - throws `RemoteSyncPatchDiscoveryError.incompatiblePatchVersion` when a remote patch targets
         a newer schema version than `currentSchemaVersion`
       - throws `RemoteSyncPatchDiscoveryError.patchFilesSkipped` when an earlier patch is missing
       - rethrows backend transport errors from the adapter
     */
    public func discoverPendingPatches(
        for category: RemoteSyncCategory,
        bootstrapState: RemoteSyncBootstrapState,
        progressState: RemoteSyncProgressState,
        currentSchemaVersion: Int
    ) async throws -> RemoteSyncPatchDiscoveryResult {
        guard let syncFolderID = bootstrapState.syncFolderID, !syncFolderID.isEmpty else {
            throw RemoteSyncPatchDiscoveryError.missingSyncFolderID
        }

        let deviceFolders = try await adapter.listFiles(
            parentIDs: [syncFolderID],
            name: nil,
            mimeType: NextCloudSyncAdapter.folderMimeType,
            modifiedAtLeast: nil
        )
        guard !deviceFolders.isEmpty else {
            return RemoteSyncPatchDiscoveryResult(deviceFolders: [], pendingPatches: [])
        }

        let modifiedAtLeast: Date?
        if let lastSynchronized = progressState.lastSynchronized, lastSynchronized > 0 {
            modifiedAtLeast = Date(timeIntervalSince1970: TimeInterval(lastSynchronized) / 1000.0)
        } else {
            modifiedAtLeast = nil
        }

        let rawPatchFiles = try await adapter.listFiles(
            parentIDs: deviceFolders.map(\.id),
            name: nil,
            mimeType: nil,
            modifiedAtLeast: modifiedAtLeast
        ).sorted { lhs, rhs in
            if lhs.timestamp == rhs.timestamp {
                return lhs.name < rhs.name
            }
            return lhs.timestamp < rhs.timestamp
        }

        struct FolderState {
            let folder: RemoteSyncFile
            let lastAppliedPatchNumber: Int64
        }

        let folderStates = Dictionary(
            uniqueKeysWithValues: deviceFolders.map { folder in
                (
                    folder.id,
                    FolderState(
                        folder: folder,
                        lastAppliedPatchNumber: statusStore.lastPatchNumber(
                            for: category,
                            sourceDevice: folder.name
                        ) ?? 0
                    )
                )
            }
        )

        let pendingPatches = try rawPatchFiles.compactMap { file -> RemoteSyncDiscoveredPatch? in
            guard let folderState = folderStates[file.parentID],
                  let parsedPatch = Self.parsePatchFileName(file.name) else {
                return nil
            }
            if parsedPatch.schemaVersion > currentSchemaVersion {
                throw RemoteSyncPatchDiscoveryError.incompatiblePatchVersion(parsedPatch.schemaVersion)
            }
            if statusStore.status(
                for: category,
                sourceDevice: folderState.folder.name,
                patchNumber: parsedPatch.patchNumber
            ) != nil {
                return nil
            }
            guard parsedPatch.patchNumber > folderState.lastAppliedPatchNumber else {
                return nil
            }
            return RemoteSyncDiscoveredPatch(
                sourceDevice: folderState.folder.name,
                patchNumber: parsedPatch.patchNumber,
                schemaVersion: parsedPatch.schemaVersion,
                file: file
            )
        }

        for folderState in folderStates.values {
            guard let firstPendingPatch = pendingPatches.first(where: { $0.sourceDevice == folderState.folder.name }) else {
                continue
            }
            if firstPendingPatch.patchNumber > folderState.lastAppliedPatchNumber + 1 {
                throw RemoteSyncPatchDiscoveryError.patchFilesSkipped
            }
        }

        return RemoteSyncPatchDiscoveryResult(
            deviceFolders: deviceFolders,
            pendingPatches: pendingPatches
        )
    }

    /**
     Parses an Android-style remote patch filename into its patch number and schema version.

     Filenames follow Android's regex `(\d+)\.((\d+)\.)?sqlite3\.gz`, where the schema version is
     optional and defaults to `1` for legacy patch archives.

     - Parameter name: Remote filename to parse.
     - Returns: Patch number and schema version when the filename matches the Android convention.
     - Side effects: none.
     - Failure modes: Invalid filenames return `nil`.
     */
    public static func parsePatchFileName(_ name: String) -> (patchNumber: Int64, schemaVersion: Int)? {
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        guard let match = patchFilePattern.firstMatch(in: name, options: [], range: range),
              let patchRange = Range(match.range(at: 1), in: name),
              let patchNumber = Int64(name[patchRange]) else {
            return nil
        }

        let schemaVersion: Int
        if let versionRange = Range(match.range(at: 3), in: name) {
            schemaVersion = Int(name[versionRange]) ?? 1
        } else {
            schemaVersion = 1
        }

        return (patchNumber, schemaVersion)
    }
}
