// RemoteSyncPublicationIdentity.swift -- Shared durable publication identity validation

import CryptoKit
import Foundation

/**
 Describes a malformed or exhausted durable remote-sync publication identity.

 These typed failures distinguish sequence exhaustion from corrupted outbox metadata. Callers may
 map them into category-specific public errors while tests and shared infrastructure retain the exact
 failed invariant. Comparing or constructing an error has no side effects.
 */
enum RemoteSyncPublicationIdentityError: Error, Equatable {
    /// No signed 64-bit patch number remains after the supplied high-water marks.
    case patchNumberExhausted

    /// The encoded identity format is not supported by this build.
    case unsupportedFormatVersion(Int)

    /// The identity names a different category than the owning outbox.
    case categoryMismatch

    /// The publication kind or sequence number is inconsistent with an initial or patch archive.
    case invalidSequence

    /// The identity schema is not the checked-in Android Room schema for its category.
    case schemaMismatch

    /// The destination or source device identity is empty or differs from the owning outbox.
    case endpointMismatch

    /// A local or remote archive filename is unsafe or disagrees with its number and schema.
    case filenameMismatch

    /// Archive size or SHA-256 metadata is malformed or differs from the owning outbox.
    case archiveMismatch

    /// Operation counts are missing, negative, or differ from the owning outbox.
    case countMismatch

    /// The canonical local-acceptance payload differs from the identity captured before transport.
    case acceptanceMismatch
}

/**
 Binds one durable outbox archive to its remote name and exact local-acceptance generation.

 The same value is embedded by all five sparse-patch uploaders and the initial-backup uploader. A
 retry must validate every duplicated field and the canonical acceptance digest before it may inspect
 or publish remote bytes, preventing a settings/archive mix-up from acknowledging the wrong local
 generation under an otherwise valid Android filename.
 */
struct RemoteSyncPublicationIdentity: Codable, Equatable, Sendable {
    /** Distinguishes Android patch zero from numbered sparse patches. */
    enum Kind: String, Codable, Sendable {
        /// Full category baseline published as `initial.sqlite3.gz`.
        case initialBackup

        /// Numbered sparse database published beneath one source-device folder.
        case patch
    }

    /// Current durable identity encoding.
    private static let currentFormatVersion = 1

    let formatVersion: Int
    let kind: Kind
    let categoryRawValue: String
    let destinationID: String
    let sourceDevice: String
    let patchNumber: Int64
    let schemaVersion: Int
    let remoteFileName: String
    let archiveFileName: String
    let archiveSHA256: String
    let archiveSize: Int64
    let rowCounts: [String: Int]
    let acceptanceSHA256: String

    /**
     Allocates the next positive Android patch number without signed overflow.

     - Parameter highWatermarks: Accepted local and discovered remote patch numbers.
     - Returns: One greater than the largest nonnegative high-water mark.
     - Side effects: none.
     - Throws: `patchNumberExhausted` when the largest value is `Int64.max` or inputs cannot produce
       a positive Android patch number.
     */
    static func nextPatchNumber(after highWatermarks: [Int64]) throws -> Int64 {
        do {
            return try RemoteSyncLogicalSequence.nextPatchNumber(after: highWatermarks)
        } catch {
            throw RemoteSyncPublicationIdentityError.patchNumberExhausted
        }
    }

    /**
     Creates and validates a numbered sparse-patch identity.

     - Parameters:
       - category: Owning remote-sync category.
       - destinationID: Source-device folder receiving the patch.
       - sourceDevice: Android source-device name encoded in logs and status.
       - patchNumber: Positive monotonic patch number.
       - schemaVersion: Exact Android Room schema version.
       - remoteFileName: Android numbered patch filename.
       - archiveFileName: Safe local outbox basename.
       - archiveSHA256: Lowercase SHA-256 of the durable gzip bytes.
       - archiveSize: Exact durable gzip byte count.
       - rowCounts: Named operation counts accepted with this generation.
       - acceptancePayload: Complete pending envelope with its identity field cleared.
     - Returns: Fully validated immutable publication identity.
     - Side effects: Canonically JSON-encodes `acceptancePayload`; performs no persistence or I/O.
     - Throws: `RemoteSyncPublicationIdentityError` for any malformed identity component and rethrows
       canonical JSON encoding failures.
     */
    static func patch<AcceptancePayload: Encodable>(
        category: RemoteSyncCategory,
        destinationID: String,
        sourceDevice: String,
        patchNumber: Int64,
        schemaVersion: Int,
        remoteFileName: String,
        archiveFileName: String,
        archiveSHA256: String,
        archiveSize: Int64,
        rowCounts: [String: Int],
        acceptancePayload: AcceptancePayload
    ) throws -> RemoteSyncPublicationIdentity {
        try make(
            kind: .patch,
            category: category,
            destinationID: destinationID,
            sourceDevice: sourceDevice,
            patchNumber: patchNumber,
            schemaVersion: schemaVersion,
            remoteFileName: remoteFileName,
            archiveFileName: archiveFileName,
            archiveSHA256: archiveSHA256,
            archiveSize: archiveSize,
            rowCounts: rowCounts,
            acceptancePayload: acceptancePayload
        )
    }

    /**
     Creates and validates an Android patch-zero initial-backup identity.

     - Parameters:
       - category: Owning remote-sync category.
       - destinationID: Category sync folder receiving `initial.sqlite3.gz`.
       - sourceDevice: Local source-device identity recorded for patch zero.
       - schemaVersion: Exact Android Room schema version.
       - remoteFileName: Android initial-backup filename.
       - archiveFileName: Safe local retry archive basename.
       - archiveSHA256: Lowercase SHA-256 of the durable gzip bytes.
       - archiveSize: Exact durable gzip byte count.
       - rowCounts: Named accepted-row counts captured with the baseline.
       - acceptancePayload: Complete pending metadata with its identity field cleared.
     - Returns: Fully validated immutable patch-zero identity.
     - Side effects: Canonically JSON-encodes `acceptancePayload`; performs no persistence or I/O.
     - Throws: `RemoteSyncPublicationIdentityError` for malformed identity and rethrows JSON encoding
       failures.
     */
    static func initialBackup<AcceptancePayload: Encodable>(
        category: RemoteSyncCategory,
        destinationID: String,
        sourceDevice: String,
        schemaVersion: Int,
        remoteFileName: String,
        archiveFileName: String,
        archiveSHA256: String,
        archiveSize: Int64,
        rowCounts: [String: Int],
        acceptancePayload: AcceptancePayload
    ) throws -> RemoteSyncPublicationIdentity {
        try make(
            kind: .initialBackup,
            category: category,
            destinationID: destinationID,
            sourceDevice: sourceDevice,
            patchNumber: 0,
            schemaVersion: schemaVersion,
            remoteFileName: remoteFileName,
            archiveFileName: archiveFileName,
            archiveSHA256: archiveSHA256,
            archiveSize: archiveSize,
            rowCounts: rowCounts,
            acceptancePayload: acceptancePayload
        )
    }

    /**
     Validates a decoded identity against its owning pending envelope.

     - Parameters mirror the persisted fields and `acceptancePayload` must have its identity cleared.
     - Side effects: Canonically JSON-encodes `acceptancePayload`; performs no persistence or I/O.
     - Throws: The precise `RemoteSyncPublicationIdentityError` for the first violated invariant, or
       a JSON encoding error when the acceptance envelope cannot be represented deterministically.
     */
    func validate<AcceptancePayload: Encodable>(
        kind expectedKind: Kind,
        category: RemoteSyncCategory,
        destinationID expectedDestinationID: String,
        sourceDevice expectedSourceDevice: String,
        patchNumber expectedPatchNumber: Int64,
        schemaVersion expectedSchemaVersion: Int,
        remoteFileName expectedRemoteFileName: String,
        archiveFileName expectedArchiveFileName: String,
        archiveSHA256 expectedArchiveSHA256: String,
        archiveSize expectedArchiveSize: Int64,
        rowCounts expectedRowCounts: [String: Int],
        acceptancePayload: AcceptancePayload
    ) throws {
        guard formatVersion == Self.currentFormatVersion else {
            throw RemoteSyncPublicationIdentityError.unsupportedFormatVersion(formatVersion)
        }
        guard kind == expectedKind, categoryRawValue == category.rawValue else {
            throw RemoteSyncPublicationIdentityError.categoryMismatch
        }
        guard patchNumber == expectedPatchNumber,
              (kind == .initialBackup ? patchNumber == 0 : patchNumber > 0) else {
            throw RemoteSyncPublicationIdentityError.invalidSequence
        }
        guard schemaVersion == expectedSchemaVersion,
              schemaVersion == RemoteSyncAndroidDatabaseContract.schemaVersion(for: category) else {
            throw RemoteSyncPublicationIdentityError.schemaMismatch
        }
        guard destinationID == expectedDestinationID,
              sourceDevice == expectedSourceDevice,
              !destinationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !sourceDevice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemoteSyncPublicationIdentityError.endpointMismatch
        }
        guard remoteFileName == expectedRemoteFileName,
              archiveFileName == expectedArchiveFileName,
              Self.isSafeBasename(archiveFileName),
              Self.isValidRemoteFileName(
                remoteFileName,
                kind: kind,
                patchNumber: patchNumber,
                schemaVersion: schemaVersion
              ) else {
            throw RemoteSyncPublicationIdentityError.filenameMismatch
        }
        guard archiveSHA256 == expectedArchiveSHA256,
              archiveSize == expectedArchiveSize,
              archiveSize > 0,
              Self.isLowercaseSHA256(archiveSHA256) else {
            throw RemoteSyncPublicationIdentityError.archiveMismatch
        }
        guard rowCounts == expectedRowCounts,
              !rowCounts.isEmpty,
              rowCounts.values.allSatisfy({ $0 >= 0 }) else {
            throw RemoteSyncPublicationIdentityError.countMismatch
        }
        guard acceptanceSHA256 == (try Self.canonicalSHA256(acceptancePayload)) else {
            throw RemoteSyncPublicationIdentityError.acceptanceMismatch
        }
    }

    /** Creates a validated identity after hashing one identity-free acceptance envelope. */
    private static func make<AcceptancePayload: Encodable>(
        kind: Kind,
        category: RemoteSyncCategory,
        destinationID: String,
        sourceDevice: String,
        patchNumber: Int64,
        schemaVersion: Int,
        remoteFileName: String,
        archiveFileName: String,
        archiveSHA256: String,
        archiveSize: Int64,
        rowCounts: [String: Int],
        acceptancePayload: AcceptancePayload
    ) throws -> RemoteSyncPublicationIdentity {
        let identity = RemoteSyncPublicationIdentity(
            formatVersion: currentFormatVersion,
            kind: kind,
            categoryRawValue: category.rawValue,
            destinationID: destinationID,
            sourceDevice: sourceDevice,
            patchNumber: patchNumber,
            schemaVersion: schemaVersion,
            remoteFileName: remoteFileName,
            archiveFileName: archiveFileName,
            archiveSHA256: archiveSHA256,
            archiveSize: archiveSize,
            rowCounts: rowCounts,
            acceptanceSHA256: try canonicalSHA256(acceptancePayload)
        )
        try identity.validate(
            kind: kind,
            category: category,
            destinationID: destinationID,
            sourceDevice: sourceDevice,
            patchNumber: patchNumber,
            schemaVersion: schemaVersion,
            remoteFileName: remoteFileName,
            archiveFileName: archiveFileName,
            archiveSHA256: archiveSHA256,
            archiveSize: archiveSize,
            rowCounts: rowCounts,
            acceptancePayload: acceptancePayload
        )
        return identity
    }

    /** Returns deterministic lowercase SHA-256 for one sorted-key JSON acceptance envelope. */
    private static func canonicalSHA256<Payload: Encodable>(_ payload: Payload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /** Returns whether one filename is a nonempty path-free basename. */
    private static func isSafeBasename(_ value: String) -> Bool {
        !value.isEmpty && URL(fileURLWithPath: value).lastPathComponent == value
    }

    /** Returns whether one digest is exactly 64 lowercase hexadecimal characters. */
    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { character in
            character.isNumber || ("a"..."f").contains(String(character))
        }
    }

    /** Returns whether the remote name exactly encodes the identity kind, number, and schema. */
    private static func isValidRemoteFileName(
        _ value: String,
        kind: Kind,
        patchNumber: Int64,
        schemaVersion: Int
    ) -> Bool {
        switch kind {
        case .initialBackup:
            return value == RemoteSyncPatchDiscoveryService.initialBackupFilename
        case .patch:
            guard let parsed = RemoteSyncPatchDiscoveryService.parsePatchFileName(value) else {
                return false
            }
            return parsed.patchNumber == patchNumber && parsed.schemaVersion == schemaVersion
        }
    }
}
