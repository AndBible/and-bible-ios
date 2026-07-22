import Foundation
import BibleCore

/**
 Deterministic remote-sync adapter used only for UI automation launch scenarios.

 The adapter gives Sync Settings a same-named remote folder without requiring live WebDAV or
 Google Drive credentials. Normal app launches never instantiate this type; `SyncSettingsView`
 only uses it when the UI-test runtime configuration explicitly requests the adopt-existing
 bootstrap branch.
 */
actor UITestRemoteSyncAdapter: RemoteSyncAdapting, RemoteSyncConditionalFileUploading {
    /**
     Process-session backend used by repeated synchronization services in the visible UI workflow.

     App relaunch creates a new process and therefore a fresh deterministic remote. Within one app
     process, every synchronization attempt observes the same synthetic objects just as repeated
     requests to a real remote backend do.
     */
    static let appSession = UITestRemoteSyncAdapter(
        bundleIdentifier: Bundle.main.bundleIdentifier ?? "org.andbible.ios"
    )

    /** One synthetic remote object together with the bytes returned by downloads. */
    private struct StoredRemoteObject: Sendable {
        let file: RemoteSyncFile
        let data: Data
    }

    /** Deterministic failures raised when the UI-test backend receives an invalid local operation. */
    private enum AdapterError: Error, Equatable {
        /// A requested remote identifier does not exist in the synthetic backend.
        case missingRemoteObject(String)

    }

    /// Bundle identity used to derive Android-compatible top-level category folder names.
    private let bundleIdentifier: String

    /// Actor-isolated remote metadata and bytes keyed by stable synthetic object identifier.
    private var remoteObjectsByID: [String: StoredRemoteObject]

    /**
     Creates a UI-test adapter bound to the current app bundle identifier.
     *
     * - Parameter bundleIdentifier: App bundle identifier used to derive Android-style sync folder names.
     * - Side effects: Seeds one synthetic top-level folder for every active sync category.
     * - Failure modes: This initializer cannot fail.
     */
    init(bundleIdentifier: String) {
        self.bundleIdentifier = bundleIdentifier
        remoteObjectsByID = Dictionary(
            uniqueKeysWithValues: RemoteSyncCategory.activeSyncCases.map { category in
                let name = category.syncFolderName(bundleIdentifier: bundleIdentifier)
                let file = RemoteSyncFile(
                    id: "/uitest-existing-\(name)",
                    name: name,
                    size: 0,
                    timestamp: 1_735_689_600_000,
                    parentID: "/",
                    mimeType: NextCloudSyncAdapter.folderMimeType
                )
                return (file.id, StoredRemoteObject(file: file, data: Data()))
            }
        )
    }

    /**
     Lists synthetic remote objects using the same parent, exact-name, MIME, and timestamp filters
     exercised by bootstrap, patch discovery, and byte reconciliation.
     *
     * - Parameters:
     *   - parentIDs: Remote parent identifiers requested by the sync coordinator.
     *   - name: Optional exact name filter.
     *   - mimeType: Optional MIME type filter.
     *   - modifiedAtLeast: Optional exclusive cursor for patch discovery.
     * - Returns: Deterministically ordered matching remote metadata.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    func listFiles(
        parentIDs: [String]?,
        name: String?,
        mimeType: String?,
        modifiedAtLeast: Date?
    ) async throws -> [RemoteSyncFile] {
        let allowedParents = parentIDs.map(Set.init)
        let minimumTimestamp = modifiedAtLeast.map {
            Int64($0.timeIntervalSince1970 * 1_000)
        }
        return remoteObjectsByID.values
            .map(\.file)
            .filter { file in
                if let allowedParents {
                    guard allowedParents.contains(file.parentID) else { return false }
                } else if file.parentID != "/" {
                    return false
                }
                if let name, file.name != name { return false }
                if let mimeType, file.mimeType != mimeType { return false }
                if let minimumTimestamp, file.timestamp <= minimumTimestamp { return false }
                return true
            }
            .sorted { $0.id < $1.id }
    }

    /**
     Creates a synthetic remote folder descriptor.
     *
     * - Parameters:
     *   - name: Requested remote folder name.
     *   - parentID: Optional parent folder identifier.
     * - Returns: Synthetic folder metadata matching the requested location.
     * - Side effects: Stores the created folder so later listings and descendant deletion observe it.
     * - Failure modes: This helper cannot fail.
     */
    func createNewFolder(name: String, parentID: String?) async throws -> RemoteSyncFile {
        let resolvedParentID = parentID ?? "/"
        let folderID: String
        if let parentID {
            folderID = "\(parentID)/\(name)"
        } else {
            folderID = "/uitest-created-\(name)"
        }

        let file = RemoteSyncFile(
            id: folderID,
            name: name,
            size: 0,
            timestamp: 1_735_689_700_000,
            parentID: resolvedParentID,
            mimeType: NextCloudSyncAdapter.folderMimeType
        )
        remoteObjectsByID[file.id] = StoredRemoteObject(file: file, data: Data())
        return file
    }

    /**
     Downloads bytes stored for one synthetic remote object.
     *
     * - Parameter id: Remote identifier requested by the sync coordinator.
     * - Returns: Exact bytes previously published for the requested object.
     * - Side effects: none.
     * - Failure modes: Throws `AdapterError.missingRemoteObject` for an unknown identifier.
     */
    func download(id: String) async throws -> Data {
        guard let object = remoteObjectsByID[id] else {
            throw AdapterError.missingRemoteObject(id)
        }
        return object.data
    }

    /**
     Uploads a synthetic remote file descriptor while consuming the local file payload.
     *
     * - Parameters:
     *   - name: Remote filename to create.
     *   - fileURL: Local file whose contents should be uploaded.
     *   - parentID: Remote parent folder identifier.
     *   - contentType: MIME type for the upload.
     * - Returns: Synthetic metadata sized to the local payload.
     * - Side effects: Reads the local file and replaces the exact synthetic destination object.
     * - Failure modes: Rethrows local file-read errors.
     */
    func upload(
        name: String,
        fileURL: URL,
        parentID: String,
        contentType: String
    ) async throws -> RemoteSyncFile {
        let data = try Data(contentsOf: fileURL)
        let file = RemoteSyncFile(
            id: childID(parentID: parentID, name: name),
            name: name,
            size: Int64(data.count),
            timestamp: 1_735_689_800_000,
            parentID: parentID,
            mimeType: contentType
        )
        remoteObjectsByID[file.id] = StoredRemoteObject(file: file, data: data)
        return file
    }

    /**
     Atomically creates one synthetic remote object without replacing an occupied destination.

     - Parameters:
       - name: Exact destination filename.
       - fileURL: Durable local archive whose bytes should be published.
       - maximumByteCount: Strict source-byte ceiling enforced before publication.
       - parentID: Synthetic remote parent identifier.
       - contentType: MIME type recorded on the created object.
     - Returns: `.created` with stored metadata, or `.alreadyExists` when the exact parent/name is occupied.
     - Side Effects: Reads at most `maximumByteCount + 1` local bytes and stores one new remote object.
     - Throws: Cancellation or BibleCore bounded-file errors when the source is unsafe, replaced, or
       larger than the reconciler permits.
     - Important: Actor isolation makes the existence check and insertion one indivisible operation.
     */
    func uploadIfAbsent(
        name: String,
        fileURL: URL,
        maximumByteCount: Int,
        parentID: String,
        contentType: String
    ) async throws -> RemoteSyncConditionalUploadResult {
        guard !remoteObjectsByID.values.contains(where: {
            $0.file.parentID == parentID && $0.file.name == name
        }) else {
            return .alreadyExists
        }

        try Task.checkCancellation()
        let data = try RemoteSyncConditionalUploadSource.readValidatedBytes(
            at: fileURL,
            maximumByteCount: maximumByteCount
        )
        try Task.checkCancellation()
        guard !remoteObjectsByID.values.contains(where: {
            $0.file.parentID == parentID && $0.file.name == name
        }) else {
            return .alreadyExists
        }

        let id = childID(parentID: parentID, name: name)
        let file = RemoteSyncFile(
            id: id,
            name: name,
            size: Int64(data.count),
            timestamp: 1_735_689_800_000,
            parentID: parentID,
            mimeType: contentType
        )
        remoteObjectsByID[id] = StoredRemoteObject(file: file, data: data)
        return .created(file)
    }

    /**
     Deletes a synthetic remote file or folder.
     *
     * - Parameter id: Remote identifier requested for deletion.
     * - Side effects: Removes the requested object and every stored descendant beneath its identifier.
     * - Failure modes: This helper cannot fail.
     */
    func delete(id: String) async throws {
        let descendantPrefix = id.hasSuffix("/") ? id : "\(id)/"
        remoteObjectsByID = remoteObjectsByID.filter { candidateID, _ in
            candidateID != id && !candidateID.hasPrefix(descendantPrefix)
        }
    }

    /**
     Reports whether the requested ownership marker was stored in the synthetic sync folder.
     *
     * - Parameters:
     *   - syncFolderID: Stored sync folder identifier.
     *   - secretFileName: Stored secret marker filename.
     * - Returns: `true` only after this adapter instance created the exact marker.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    func isSyncFolderKnown(syncFolderID: String, secretFileName: String) async throws -> Bool {
        remoteObjectsByID[childID(parentID: syncFolderID, name: secretFileName)] != nil
    }

    /**
     Creates and stores a deterministic synthetic ownership marker.
     *
     * - Parameters:
     *   - syncFolderID: Sync folder receiving the marker.
     *   - deviceIdentifier: Stable device identifier from remote sync settings.
     * - Returns: Synthetic marker filename.
     * - Side effects: Stores an empty marker file beneath the supplied sync folder.
     * - Failure modes: This helper cannot fail.
     */
    func makeSyncFolderKnown(syncFolderID: String, deviceIdentifier: String) async throws -> String {
        let name = "uitest-\(deviceIdentifier)-secret"
        let file = RemoteSyncFile(
            id: childID(parentID: syncFolderID, name: name),
            name: name,
            size: 0,
            timestamp: 1_735_689_800_000,
            parentID: syncFolderID,
            mimeType: "application/octet-stream"
        )
        remoteObjectsByID[file.id] = StoredRemoteObject(file: file, data: Data())
        return name
    }

    /**
     Builds a stable child identifier without introducing duplicate path separators.

     - Parameters:
       - parentID: Synthetic parent identifier.
       - name: Exact child name.
     - Returns: One slash-delimited child identifier.
     - Side Effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func childID(parentID: String, name: String) -> String {
        parentID.hasSuffix("/") ? "\(parentID)\(name)" : "\(parentID)/\(name)"
    }

}
