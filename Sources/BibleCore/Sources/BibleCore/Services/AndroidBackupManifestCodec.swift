// AndroidBackupManifestCodec.swift -- Shared Android backup-manifest contract

import Foundation

/** Normalized fields carried by Android's `AndBibleBackupManifest.json`. */
struct AndroidBackupManifestPayload: Sendable, Equatable {
    /// Android backup-kind enum name.
    let backupType: String

    /// Android database-kind enum names, or `nil` for non-database archives.
    let contains: [String]?

    /// Manifest schema version when explicitly encoded.
    let manifestVersion: Int?

    /// Producing application build when explicitly encoded.
    let andBibleVersion: Int?
}

/**
 Owns the common JSON and producer-version contract for every Android-compatible backup exporter.

 Android's Kotlin serializer writes all four fields in declaration order and includes nullable
 values. Centralizing that behavior prevents module, database, and Study Pad archives from silently
 diverging while keeping each archive service responsible for its own payload and validation rules.
 */
enum AndroidBackupManifestCodec {
    static let fileName = "AndBibleBackupManifest.json"
    static let supportedManifestVersion = 1

    private struct DecodedManifest: Decodable {
        let backupType: String
        let contains: [String]?
        let manifestVersion: Int?
        let andBibleVersion: Int?
    }

    private struct AndroidDefaultedManifest: Decodable {
        let backupType: String
        let contains: [String]?
        let manifestVersion: Int
        let andBibleVersion: Int

        private enum CodingKeys: String, CodingKey {
            case backupType
            case contains
            case manifestVersion
            case andBibleVersion
        }

        /// Mirrors Kotlin defaults while rejecting explicit nulls for non-null integer fields.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            backupType = try container.decode(String.self, forKey: .backupType)
            contains = try container.decodeIfPresent([String].self, forKey: .contains)
            manifestVersion = container.contains(.manifestVersion)
                ? try container.decode(Int.self, forKey: .manifestVersion)
                : AndroidBackupManifestCodec.supportedManifestVersion
            andBibleVersion = container.contains(.andBibleVersion)
                ? try container.decode(Int.self, forKey: .andBibleVersion)
                : 0
        }
    }

    /**
     Returns the integer application build Android records as `andBibleVersion`.

     - Parameter bundle: Bundle owning `CFBundleVersion`; command-line test hosts may omit it.
     - Returns: Parsed numeric build, or Android-compatible sentinel `0` when unavailable.
     - Side effects: Reads bundle metadata only.
     - Failure modes: None; nonnumeric values resolve to zero.
     */
    static func producerVersion(bundle: Bundle = .main) -> Int {
        let value = bundle.object(forInfoDictionaryKey: "CFBundleVersion")
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String, let number = Int(string) { return number }
        return 0
    }

    /**
     Encodes Android's complete four-field manifest in Kotlin declaration order.

     - Parameters:
       - backupType: Android `BackupType` enum name.
       - contains: Ordered Android `DbType` names, or nil for a literal JSON `null`.
       - manifestVersion: Manifest schema version.
       - andBibleVersion: Integer producer build.
     - Returns: UTF-8 JSON bytes accepted by Android's kotlinx serializer.
     - Side effects: None.
     - Failure modes: Rethrows JSON string/array encoding failures.
     */
    static func encode(
        backupType: String,
        contains: [String]?,
        manifestVersion: Int = supportedManifestVersion,
        andBibleVersion: Int
    ) throws -> Data {
        let backupTypeData = try JSONEncoder().encode(backupType)
        guard let encodedBackupType = String(data: backupTypeData, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                backupType,
                .init(codingPath: [], debugDescription: "Backup type was not UTF-8.")
            )
        }
        let encodedContains: String
        if let contains {
            let containsData = try JSONEncoder().encode(contains)
            guard let value = String(data: containsData, encoding: .utf8) else {
                throw EncodingError.invalidValue(
                    contains,
                    .init(codingPath: [], debugDescription: "Backup categories were not UTF-8.")
                )
            }
            encodedContains = value
        } else {
            encodedContains = "null"
        }
        return Data(
            "{\"backupType\":\(encodedBackupType),\"contains\":\(encodedContains),"
                .appending("\"manifestVersion\":\(manifestVersion),")
                .appending("\"andBibleVersion\":\(andBibleVersion)}")
                .utf8
        )
    }

    /**
     Decodes the shared manifest shape while preserving whether Android optional fields were absent.

     - Parameter data: Raw `AndBibleBackupManifest.json` bytes.
     - Returns: Normalized raw string fields for archive-specific validation.
     - Side effects: None.
     - Failure modes: Rethrows malformed JSON and required-field type failures.
     */
    static func decode(_ data: Data) throws -> AndroidBackupManifestPayload {
        let decoded = try JSONDecoder().decode(DecodedManifest.self, from: data)
        return AndroidBackupManifestPayload(
            backupType: decoded.backupType,
            contains: decoded.contains,
            manifestVersion: decoded.manifestVersion,
            andBibleVersion: decoded.andBibleVersion
        )
    }

    /**
     Decodes with Android Kotlin defaults and non-null field strictness.

     Specialized install routing uses this form because Android rejects explicit JSON `null` for
     `manifestVersion` or `andBibleVersion`, while genuinely absent fields receive runtime defaults.

     - Parameter data: Raw manifest bytes.
     - Returns: Payload with manifest and producer defaults materialized.
     - Side effects: None.
     - Failure modes: Rethrows malformed JSON, missing backup type, and explicit-null/type errors.
     */
    static func decodeUsingAndroidDefaults(_ data: Data) throws -> AndroidBackupManifestPayload {
        let decoded = try JSONDecoder().decode(AndroidDefaultedManifest.self, from: data)
        return AndroidBackupManifestPayload(
            backupType: decoded.backupType,
            contains: decoded.contains,
            manifestVersion: decoded.manifestVersion,
            andBibleVersion: decoded.andBibleVersion
        )
    }
}
