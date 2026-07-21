// RemoteSyncRemotePatchReconciler.swift — Create-only remote patch publication and byte reconciliation

import Foundation

/**
 Reports the outcome of a backend's create-only remote file operation.

 The distinct occupied-destination result lets patch reconciliation recover from a concurrent writer
 without weakening the create-only guarantee or interpreting a transport error as an existing file.
 */
public enum RemoteSyncConditionalUploadResult: Sendable, Equatable {
    /// The backend atomically created the destination from the supplied bytes.
    case created(RemoteSyncFile)

    /// Another resource already occupies the requested destination name.
    case alreadyExists
}

/**
 Narrow capability for remote backends that can atomically create a file without replacing one.

 This protocol remains separate from `RemoteSyncAdapting` so existing backends and test doubles do not
 acquire a create-only requirement before they can implement it safely.
 */
public protocol RemoteSyncConditionalFileUploading: Sendable {
    /**
     Atomically creates a remote file only when its destination does not already exist.

     - Parameters:
       - name: Exact destination filename.
       - fileURL: Durable immutable file to create remotely.
       - maximumByteCount: Maximum accepted source bytes.
       - parentID: Remote parent folder identifier.
       - contentType: MIME type sent with the upload request.
     - Returns: Whether the destination was created or was already occupied.
     - Side effects: May perform one remote create request; implementations must never retry with an
       unconditional overwrite.
     - Throws: Transport, authentication, or cancellation failures. An occupied destination must be
       returned as `.alreadyExists`, not thrown as a generic transport failure.
     */
    func uploadIfAbsent(
        name: String,
        fileURL: URL,
        maximumByteCount: Int,
        parentID: String,
        contentType: String
    ) async throws -> RemoteSyncConditionalUploadResult
}

/**
 Shared local-source validation for conditional-upload implementations that materialize bytes.

 Production network adapters may stream a validated descriptor directly. In-memory and deterministic
 adapters use this namespace to enforce the same no-follow, regular-file, byte-ceiling, complete-read,
 and identity-revalidation boundary instead of maintaining weaker file readers in other modules.
 */
public enum RemoteSyncConditionalUploadSource {
    /**
     Reads one complete conditional-upload source through BibleCore's bounded-file safety contract.

     - Parameters:
       - fileURL: Local source that must remain the same regular file throughout the read.
       - maximumByteCount: Maximum accepted source size.
     - Returns: Exact source bytes after descriptor and path identity revalidation.
     - Side Effects: Opens and reads one no-follow local file descriptor.
     - Throws: Cancellation is handled by callers; missing, unsafe, replaced, or oversized sources
       throw BibleCore's bounded-file error without returning partial bytes.
     */
    public static func readValidatedBytes(
        at fileURL: URL,
        maximumByteCount: Int
    ) throws -> Data {
        try RemoteSyncBoundedFileIO.readRegularFile(
            at: fileURL,
            maximumByteCount: maximumByteCount
        )
    }
}

/**
 Immutable identity and location of a durable local patch generation awaiting remote acceptance.

 Category workers construct this value from their persisted outbox manifest. The reconciler validates
 the file against `size` and `sha256` before any remote request, ensuring retries publish the exact
 generation that local acceptance metadata describes.
 */
public struct RemoteSyncDurablePatchArchive: Sendable, Equatable {
    /// Exact remote patch filename, including schema and patch-number components.
    public let fileName: String

    /// Durable local file URL whose bytes must survive retries until local acceptance commits.
    public let fileURL: URL

    /// Lowercase or uppercase 64-character SHA-256 digest of the durable archive bytes.
    public let sha256: String

    /// Expected archive byte count recorded with the durable generation.
    public let size: Int64

    /// Remote device-folder identifier that owns the patch namespace.
    public let parentID: String

    /// MIME type used when conditionally creating the remote patch.
    public let contentType: String

    /**
     Creates a durable patch identity for later validation and remote reconciliation.

     - Parameters:
       - fileName: Exact remote patch filename.
       - fileURL: Durable local archive URL.
       - sha256: Expected 64-character SHA-256 digest.
       - size: Expected archive byte count; must be nonnegative when reconciled.
       - parentID: Remote device-folder identifier.
       - contentType: MIME type for a conditional create.
     - Side effects: none.
     - Failure modes: This initializer does not access the file or validate metadata; reconciliation
       fails closed if any value does not match the durable bytes.
     */
    public init(
        fileName: String,
        fileURL: URL,
        sha256: String,
        size: Int64,
        parentID: String,
        contentType: String
    ) {
        self.fileName = fileName
        self.fileURL = fileURL
        self.sha256 = sha256
        self.size = size
        self.parentID = parentID
        self.contentType = contentType
    }
}

/**
 Successful resolution of one durable patch generation against its exact remote filename.
 */
public enum RemoteSyncRemotePatchReconciliationResult: Sendable, Equatable {
    /// The reconciler conditionally created the previously absent remote patch.
    case created(RemoteSyncFile)

    /// Every existing exact-name candidate contained the expected archive bytes.
    case matchedExisting(RemoteSyncFile)
}

/**
 Fail-closed validation and capability errors raised during remote patch reconciliation.

 Backend transport, authentication, filesystem, and cancellation errors are rethrown unchanged so
 callers can apply their existing retry and presentation policies.
 */
public enum RemoteSyncRemotePatchReconciliationError: Error, Sendable, Equatable {
    /// The durable manifest records a negative byte count.
    case invalidArchiveSize(Int64)

    /// The durable manifest does not contain a 64-character hexadecimal SHA-256 digest.
    case invalidArchiveSHA256(String)

    /// The local durable archive byte count differs from the persisted generation metadata.
    case localArchiveSizeMismatch(expected: Int64, actual: Int64)

    /// The local durable archive digest differs from the persisted generation metadata.
    case localArchiveDigestMismatch

    /// No local archive remains to supply bytes for an absent remote destination.
    case localArchiveMissing

    /// At least one exact-name remote candidate differs from the durable archive bytes.
    case conflictingRemotePatch(String)

    /// The destination is absent but the backend cannot atomically create it without overwrite risk.
    case conditionalUploadUnavailable(String)

    /// A create precondition lost a race, but the winning exact-name file was not visible on re-list.
    case preconditionRaceUnresolved(String)
}

/**
 Reconciles one durable local patch generation against an exact remote destination without overwrites.

 Existing exact-name candidates are all streamed through bounded temporary files and compared with the
 durable manifest's byte count and SHA-256; when a manifest-valid local archive remains, direct byte
 equality is checked too. A
 candidate set is accepted only when every member has the expected bytes. When no candidate exists,
 the reconciler requires valid local bytes plus a conditional uploader and performs one atomic create.
 A precondition race is resolved by one fresh list/download/verification pass.

 Side effects:
 - reads the durable local archive through a bounded no-follow descriptor when it remains available
 - lists the remote parent once, or twice after a lost create race
 - downloads every exact-name candidate returned by each accepted listing
 - may perform one conditional remote create

 - Important: This type never invokes `RemoteSyncAdapting.upload`, so an absent conditional capability
   fails closed instead of falling back to an unconditional overwrite.
 - Important: Calls are cancellation-aware between filesystem and network operations. Cancellation is
   rethrown without attempting a create or another reconciliation pass.
 */
public struct RemoteSyncRemotePatchReconciler: Sendable {
    /// Reconciliation handles patches and initial backups, so it admits the larger shared ceiling.
    private static let maximumArchiveByteCount =
        RemoteSyncArchiveStagingService.maximumCompressedInitialBackupByteCount

    private let adapter: any RemoteSyncAdapting
    private let conditionalUploader: (any RemoteSyncConditionalFileUploading)?

    /**
     Creates a reconciler for one remote backend.

     - Parameters:
       - adapter: Base adapter used only for exact-name listing and candidate downloads.
       - conditionalUploader: Optional create-only capability. When omitted, the initializer uses the
         adapter itself if it conforms to `RemoteSyncConditionalFileUploading`.
     - Side effects: none.
     - Failure modes: This initializer cannot fail. An absent create-only capability is reported only
       if reconciliation finds no existing exact-name patch.
     */
    public init(
        adapter: any RemoteSyncAdapting,
        conditionalUploader: (any RemoteSyncConditionalFileUploading)? = nil
    ) {
        self.adapter = adapter
        self.conditionalUploader = conditionalUploader
            ?? (adapter as? any RemoteSyncConditionalFileUploading)
    }

    /**
     Resolves a durable patch against remote state without replacing any existing destination.

     - Parameter archive: Durable archive URL and immutable name, digest, size, parent, and MIME identity.
     - Returns: `.matchedExisting` for verified pre-existing or race-winning bytes, or `.created` after
       a successful atomic create.
     - Side effects: Optionally reads one local file, performs remote listing/download requests, and
       may perform one conditional create request.
     - Throws:
       - `CancellationError` when cancellation is observed before or between operations
       - `RemoteSyncRemotePatchReconciliationError` for invalid metadata, missing or changed local bytes
         needed for create, conflicting remote bytes, missing conditional capability, or an unresolved
         precondition race
       - underlying filesystem and backend errors unchanged
     - Important: All exact-name candidates are verified before one is accepted. Finding one match does
       not hide another same-name candidate with inconsistent bytes.
     */
    public func reconcile(
        archive: RemoteSyncDurablePatchArchive
    ) async throws -> RemoteSyncRemotePatchReconciliationResult {
        let expectedDigest = try validatedDigest(archive.sha256)
        guard archive.size >= 0,
              archive.size <= Int64(Self.maximumArchiveByteCount) else {
            throw RemoteSyncRemotePatchReconciliationError.invalidArchiveSize(archive.size)
        }

        if let existing = try await verifiedExistingPatch(
            archive: archive,
            expectedDigest: expectedDigest
        ) {
            return .matchedExisting(existing)
        }

        try Task.checkCancellation()
        let localFingerprint = try localArchiveFingerprintIfPresent(
            at: archive.fileURL,
            maximumByteCount: Int(archive.size)
        )
        try Task.checkCancellation()
        guard let localFingerprint else {
            throw RemoteSyncRemotePatchReconciliationError.localArchiveMissing
        }
        guard localFingerprint.byteCount == archive.size else {
            throw RemoteSyncRemotePatchReconciliationError.localArchiveSizeMismatch(
                expected: archive.size,
                actual: localFingerprint.byteCount
            )
        }
        guard localFingerprint.sha256 == expectedDigest else {
            throw RemoteSyncRemotePatchReconciliationError.localArchiveDigestMismatch
        }

        guard let conditionalUploader else {
            throw RemoteSyncRemotePatchReconciliationError.conditionalUploadUnavailable(archive.fileName)
        }
        try Task.checkCancellation()
        let uploadResult = try await conditionalUploader.uploadIfAbsent(
            name: archive.fileName,
            fileURL: archive.fileURL,
            maximumByteCount: Int(archive.size),
            parentID: archive.parentID,
            contentType: archive.contentType
        )
        try Task.checkCancellation()

        switch uploadResult {
        case .created(let file):
            return .created(file)
        case .alreadyExists:
            guard let existing = try await verifiedExistingPatch(
                archive: archive,
                expectedDigest: expectedDigest
            ) else {
                throw RemoteSyncRemotePatchReconciliationError.preconditionRaceUnresolved(archive.fileName)
            }
            return .matchedExisting(existing)
        }
    }

    /**
     Lists and verifies every exact-name candidate currently visible in the remote parent.

     - Parameters:
       - archive: Durable patch identity that supplies the exact filename and parent.
       - expectedDigest: Normalized lowercase SHA-256 digest already validated by the caller.
     - Returns: A deterministic matching candidate, or `nil` when no exact-name candidate exists.
     - Side effects: Performs one remote listing and one download per exact-name candidate.
     - Throws: Cancellation and backend errors unchanged, or `conflictingRemotePatch` when any candidate
       differs by downloaded size, SHA-256, or exact bytes.
     */
    private func verifiedExistingPatch(
        archive: RemoteSyncDurablePatchArchive,
        expectedDigest: String
    ) async throws -> RemoteSyncFile? {
        try Task.checkCancellation()
        let listed = try await adapter.listFiles(
            parentIDs: [archive.parentID],
            name: archive.fileName,
            mimeType: nil,
            modifiedAtLeast: nil
        )
        let candidates = listed
            .filter { $0.name == archive.fileName }
            .sorted { $0.id < $1.id }
        guard !candidates.isEmpty else {
            return nil
        }

        for candidate in candidates {
            try Task.checkCancellation()
            let temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
                "remote-sync-reconciliation-\(UUID().uuidString).sqlite3.gz"
            )
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            do {
                let downloadedByteCount = try await adapter.download(
                    id: candidate.id,
                    to: temporaryURL,
                    maximumByteCount: Int(archive.size)
                )
                guard downloadedByteCount == archive.size else {
                    throw RemoteSyncRemotePatchReconciliationError.conflictingRemotePatch(
                        archive.fileName
                    )
                }
                try Task.checkCancellation()
                let remoteFingerprint = try RemoteSyncBoundedFileIO.fingerprintRegularFile(
                    at: temporaryURL,
                    maximumByteCount: Int(archive.size)
                )
                guard remoteFingerprint.byteCount == archive.size,
                      remoteFingerprint.sha256 == expectedDigest else {
                    throw RemoteSyncRemotePatchReconciliationError.conflictingRemotePatch(
                        archive.fileName
                    )
                }
            } catch is RemoteSyncBoundedDownloadError {
                throw RemoteSyncRemotePatchReconciliationError.conflictingRemotePatch(
                    archive.fileName
                )
            } catch RemoteSyncBoundedFileError.compressedSizeExceeded {
                throw RemoteSyncRemotePatchReconciliationError.conflictingRemotePatch(
                    archive.fileName
                )
            }
        }
        return candidates[0]
    }

    /**
     Loads the durable archive through a bounded no-follow descriptor when it still exists.

     - Parameter fileURL: Durable archive location recorded by the category outbox.
     - Returns: Archive bytes, or `nil` when the file no longer exists.
     - Side effects: Reads the local filesystem when the path exists.
     - Throws: Filesystem failures other than a missing file.
     - Note: A missing archive can still reconcile successfully when exact remote bytes match the
       persisted manifest, but it cannot authorize creation of an absent remote patch.
     */
    private func localArchiveFingerprintIfPresent(
        at fileURL: URL,
        maximumByteCount: Int
    ) throws -> RemoteSyncRegularFileFingerprint? {
        do {
            return try RemoteSyncBoundedFileIO.fingerprintRegularFile(
                at: fileURL,
                maximumByteCount: maximumByteCount
            )
        } catch RemoteSyncBoundedFileError.missingInput {
            return nil
        }
    }

    /**
     Validates and normalizes a persisted SHA-256 digest before it participates in reconciliation.

     - Parameter digest: Persisted hexadecimal digest supplied by a category outbox manifest.
     - Returns: Lowercase 64-character hexadecimal digest.
     - Side effects: none.
     - Throws: `invalidArchiveSHA256` when length or characters do not encode SHA-256.
     */
    private func validatedDigest(_ digest: String) throws -> String {
        let normalized = digest.lowercased()
        let hexadecimal = CharacterSet(charactersIn: "0123456789abcdef")
        guard normalized.utf8.count == 64,
              normalized.unicodeScalars.allSatisfy(hexadecimal.contains) else {
            throw RemoteSyncRemotePatchReconciliationError.invalidArchiveSHA256(digest)
        }
        return normalized
    }

}
