import Foundation

/**
 Resolves the application version metadata shown by native iOS information surfaces.

 This helper centralizes bundle metadata lookup so Settings, About, Help, and reader drawer
 footer text do not drift or fall back to hard-coded display values.

 - Inputs: A `Bundle`, defaulting to `Bundle.main`.
 - Outputs: Marketing version, build number, and formatted display strings.
 - Side effects: none.
 - Failure modes: Missing or non-string bundle values fall back to stable development defaults.
 */
struct AndBibleAppVersionMetadata: Equatable {
    let marketingVersion: String
    let buildNumber: String

    /// Compact version-and-build detail text suitable for secondary labels.
    var detailText: String {
        "\(marketingVersion) (\(buildNumber))"
    }

    /// App-prefixed help footer text.
    var helpFooterText: String {
        "AndBible v\(marketingVersion)"
    }

    /// Reader drawer footer text.
    var drawerFooterText: String {
        "Version \(detailText)"
    }

    /**
     Reads application version metadata from a bundle.

     - Parameter bundle: The bundle that owns `CFBundleShortVersionString` and `CFBundleVersion`.
     - Returns: A metadata value with normalized fallback strings.
     - Side effects: none.
     - Failure modes: Invalid or absent bundle keys return `1.0` and `1`.
     */
    static func current(bundle: Bundle = .main) -> AndBibleAppVersionMetadata {
        AndBibleAppVersionMetadata(
            marketingVersion: bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
            buildNumber: bundle.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        )
    }
}
