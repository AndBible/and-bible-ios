import Foundation
import BibleCore

/**
 Deterministic remote-sync adapter used only for UI automation launch scenarios.

 The adapter gives Sync Settings a same-named remote folder without requiring live WebDAV or
 Google Drive credentials. Normal app launches never instantiate this type; `SyncSettingsView`
 only uses it when the UI-test runtime configuration explicitly requests the adopt-existing
 bootstrap branch.
 */
actor UITestRemoteSyncAdapter: RemoteSyncAdapting {
    private let bundleIdentifier: String

    /**
     Creates a UI-test adapter bound to the current app bundle identifier.
     *
     * - Parameter bundleIdentifier: App bundle identifier used to derive Android-style sync folder names.
     * - Side effects: none.
     * - Failure modes: This initializer cannot fail.
     */
    init(bundleIdentifier: String) {
        self.bundleIdentifier = bundleIdentifier
    }

    /**
     Lists one synthetic same-named top-level category folder, then no child files.
     *
     * - Parameters:
     *   - parentIDs: Remote parent identifiers requested by the sync coordinator.
     *   - name: Optional exact name filter.
     *   - mimeType: Optional MIME type filter.
     *   - modifiedAtLeast: Optional lower bound for patch discovery.
     * - Returns: A synthetic category folder for top-level adoption discovery, otherwise empty.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    func listFiles(
        parentIDs: [String]?,
        name: String?,
        mimeType: String?,
        modifiedAtLeast: Date?
    ) async throws -> [RemoteSyncFile] {
        guard parentIDs == nil,
              mimeType == nil,
              let name,
              RemoteSyncCategory.allCases.contains(where: {
                  $0.syncFolderName(bundleIdentifier: bundleIdentifier) == name
              }) else {
            return []
        }

        return [
            RemoteSyncFile(
                id: "/uitest-existing-\(name)",
                name: name,
                size: 0,
                timestamp: 1_735_689_600_000,
                parentID: "/",
                mimeType: NextCloudSyncAdapter.folderMimeType
            )
        ]
    }

    /**
     Creates a synthetic remote folder descriptor.
     *
     * - Parameters:
     *   - name: Requested remote folder name.
     *   - parentID: Optional parent folder identifier.
     * - Returns: Synthetic folder metadata matching the requested location.
     * - Side effects: none.
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

        return RemoteSyncFile(
            id: folderID,
            name: name,
            size: 0,
            timestamp: 1_735_689_700_000,
            parentID: resolvedParentID,
            mimeType: NextCloudSyncAdapter.folderMimeType
        )
    }

    /**
     Downloads a synthetic remote payload.
     *
     * - Parameter id: Remote identifier requested by the sync coordinator.
     * - Returns: Empty data because the issue #44 workflow validates the create-new branch.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    func download(id: String) async throws -> Data {
        Data()
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
     * - Side effects: reads the local file so upload failures still surface during UI tests.
     * - Failure modes: Rethrows local file-read errors.
     */
    func upload(
        name: String,
        fileURL: URL,
        parentID: String,
        contentType: String
    ) async throws -> RemoteSyncFile {
        let data = try Data(contentsOf: fileURL)
        return RemoteSyncFile(
            id: "\(parentID)/\(name)",
            name: name,
            size: Int64(data.count),
            timestamp: 1_735_689_800_000,
            parentID: parentID,
            mimeType: contentType
        )
    }

    /**
     Deletes a synthetic remote file or folder.
     *
     * - Parameter id: Remote identifier requested for deletion.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    func delete(id: String) async throws {}

    /**
     Reports that no stored ownership marker is valid.
     *
     * - Parameters:
     *   - syncFolderID: Stored sync folder identifier.
     *   - secretFileName: Stored secret marker filename.
     * - Returns: Always `false` so the UI test reaches the adoption prompt.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    func isSyncFolderKnown(syncFolderID: String, secretFileName: String) async throws -> Bool {
        false
    }

    /**
     Creates a deterministic synthetic ownership marker name.
     *
     * - Parameters:
     *   - syncFolderID: Sync folder receiving the marker.
     *   - deviceIdentifier: Stable device identifier from remote sync settings.
     * - Returns: Synthetic marker filename.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    func makeSyncFolderKnown(syncFolderID: String, deviceIdentifier: String) async throws -> String {
        "uitest-\(deviceIdentifier)-secret"
    }
}
