import Foundation
import XCTest
@testable import BibleCore
import SwordKit

/**
 Verifies the shared Android backup-manifest producer and restore version contracts.

 Produced manifests must use the one pinned Android compatibility code regardless of iOS bundle
 metadata. Restore must continue preserving explicit Android values and distinguishing an absent
 field for callers that apply Android defaults. The suite performs bounded in-memory JSON work only
 and has no filesystem, bundle, or database side effects.
 */
final class AndroidBackupManifestCodecTests: XCTestCase {
    /**
     Verifies iOS-produced manifests cannot substitute local or TestFlight build metadata.

     - Setup: Encodes a module manifest through the only production encoder; no Bundle input exists.
     - Expected result: The manifest carries the shared pinned Android version code and all four
       Android fields.
     - Side effects: Allocates bounded JSON data only.
     - Failure meaning: A backup producer has regained an independent or iOS-derived version seam.
     */
    func testProducedManifestUsesSharedAndroidCompatibilityCode() throws {
        let data = try AndroidBackupManifestCodec.encodeProducedBackup(
            backupType: "MODULE_BACKUP",
            contains: nil
        )
        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(manifest["backupType"] as? String, "MODULE_BACKUP")
        XCTAssertTrue(manifest.keys.contains("contains"))
        XCTAssertEqual(manifest["manifestVersion"] as? Int, 1)
        XCTAssertEqual(
            manifest["andBibleVersion"] as? Int,
            AndBibleAndroidCompatibility.currentVersionCode
        )
    }

    /**
     Verifies restore decoding keeps Android-supplied values and existing missing-field behavior.

     - Setup: Decodes one manifest with an explicit future Android version and one without the field
       through both raw and Android-defaulting paths.
     - Expected result: The explicit value survives, raw absence remains nil, and Android-defaulted
       absence remains the established zero sentinel.
     - Side effects: Allocates bounded JSON data only.
     - Failure meaning: Producer cleanup has accidentally changed restore compatibility semantics.
     */
    func testRestorePreservesExplicitAndMissingAndroidVersions() throws {
        let explicit = try AndroidBackupManifestCodec.decode(
            Data(#"{"backupType":"DB_BACKUP","andBibleVersion":99999}"#.utf8)
        )
        let absentData = Data(#"{"backupType":"DB_BACKUP"}"#.utf8)
        let absent = try AndroidBackupManifestCodec.decode(absentData)
        let defaulted = try AndroidBackupManifestCodec.decodeUsingAndroidDefaults(absentData)

        XCTAssertEqual(explicit.andBibleVersion, 99_999)
        XCTAssertNil(absent.andBibleVersion)
        XCTAssertEqual(defaulted.andBibleVersion, 0)
    }
}
