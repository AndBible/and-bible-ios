import Foundation

/**
 Owns the pinned Android JSword versification registry and its bundled mapping resources.

 SwordKit is the module-admission boundary, while BibleCore performs higher-level conversions. Both
 layers must consult the same Android-derived registry: accepting a canon only because libsword knows
 its name can expose a module Android rejects, and accepting a JSword-only canon that libsword cannot
 render can mis-number content. Resource loading fails closed when the fixture is missing, malformed,
 or from a different JSword revision.
 */
public enum JSwordVersificationRegistry {
    /// JSword revision used for the canon fixture and every bundled mapping resource.
    public static let pinnedRevision = "0da7412d7716731f402c9002a0b92e4c00ef30eb"

    /// Minimal fixture shape needed to validate revision and enumerate registered systems.
    private struct FixtureHeader: Decodable {
        /// Revision recorded by the generated canon fixture.
        let jswordRevision: String
        /// Named JSword systems; values are intentionally decoded only for structural validity.
        let systems: [String: SystemMarker]
    }

    /// Marker that accepts a structured system object while ignoring its canon dimensions.
    private struct SystemMarker: Decodable {}

    /// Validated fixture bytes and canonical system names cached for the process lifetime.
    private struct LoadedFixture {
        /// Original bytes consumed by BibleCore's full canon decoder.
        let data: Data
        /// Exact case-sensitive names registered by the pinned JSword fixture.
        let systemNames: Set<String>
    }

    /// One-time, fail-closed fixture load shared by registry and resource APIs.
    private static let loadedFixture: LoadedFixture? = {
        guard let url = Bundle.module.url(
                  forResource: "canons",
                  withExtension: "json",
                  subdirectory: "versification"
              ),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(FixtureHeader.self, from: data),
              decoded.jswordRevision == pinnedRevision,
              decoded.systems["KJV"] != nil,
              decoded.systems["KJVA"] != nil else {
            return nil
        }
        return LoadedFixture(data: data, systemNames: Set(decoded.systems.keys))
    }()

    /**
     Returns every versification defined by Android's pinned JSword dependency.

     - Returns: Exact case-sensitive system names, or an empty set when resource validation fails.
     - Side effects: Reads and decodes the bundled canon fixture on first access.
     - Failure modes: Missing, malformed, or revision-mismatched data yields an empty set.
     */
    public static var supportedNames: Set<String> {
        loadedFixture?.systemNames ?? []
    }

    /**
     Normalizes Android's absent-versification default and validates registry membership.

     - Parameter rawValue: Module or payload versification name; whitespace-only input means KJV.
     - Returns: Canonical fixture key, or `nil` when JSword does not define the system.
     - Side effects: Reads and decodes the bundled canon fixture on first access.
     - Failure modes: Invalid fixture data and unknown or mis-cased names return `nil`.
     */
    public static func normalizedName(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.isEmpty ? "KJV" : trimmed
        guard loadedFixture?.systemNames.contains(candidate) == true else { return nil }
        return candidate
    }

    /**
     Reports whether Android's pinned JSword dependency defines a versification.

     - Parameter rawValue: Module or payload versification name; empty means KJV.
     - Returns: `true` only for a validated registry member.
     - Side effects: Reads and decodes the bundled canon fixture on first access.
     - Failure modes: Resource validation failure returns `false` for every name.
     */
    public static func supports(_ rawValue: String) -> Bool {
        normalizedName(rawValue) != nil
    }

    /**
     Provides the validated JSword canon fixture to the higher-level conversion layer.

     - Returns: Original JSON bytes, or `nil` when fixture validation failed.
     - Side effects: Reads the bundled fixture on first access.
     - Failure modes: Missing, malformed, or revision-mismatched data returns `nil`.
     */
    public static func canonFixtureData() -> Data? {
        loadedFixture?.data
    }

    /**
     Loads a pinned JSword mapping resource for one registered versification.

     - Parameter rawValue: Exact or defaultable versification name.
     - Returns: UTF-8 property-file bytes when that system has an explicit mapping resource; `nil`
       for identity-only systems, unsupported names, or unreadable resources.
     - Side effects: Reads the requested file from SwordKit's resource bundle.
     - Failure modes: Registry validation and path lookup fail closed; caller distinguishes an absent
       identity mapping from malformed bytes while decoding the returned data.
     */
    public static func mappingResourceData(for rawValue: String) -> Data? {
        guard let name = normalizedName(rawValue),
              let url = Bundle.module.url(
                  forResource: name,
                  withExtension: "properties",
                  subdirectory: "versification"
              ) else {
            return nil
        }
        return try? Data(contentsOf: url)
    }
}
