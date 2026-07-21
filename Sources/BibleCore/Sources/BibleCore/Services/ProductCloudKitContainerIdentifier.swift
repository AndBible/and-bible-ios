// ProductCloudKitContainerIdentifier.swift - App-owned CloudKit container contract

import Foundation

/**
 Errors produced while resolving the app's CloudKit container identifier from bundle metadata.

 The app bundle owns the concrete value through Info.plist. Keeping malformed or unresolved values
 explicit prevents SwiftData and `SyncService` from silently opening different stores.
 */
public enum ProductCloudKitContainerIdentifierError: Error, Equatable, Sendable {
    /// The processed Info.plist does not contain a non-empty string for the required metadata key.
    case missingInfoPlistValue(key: String)

    /// The processed value is not a concrete CloudKit container identifier.
    case invalidIdentifier(String)
}

/**
 Validated identifier for the CloudKit container owned by the installed AndBible app.

 The concrete identifier comes from the app's processed Info.plist. The same value is injected into
 SwiftData and `SyncService`, preventing account-status checks from drifting from persistence.
 */
public struct ProductCloudKitContainerIdentifier: Equatable, Hashable, Sendable {
    /// Info.plist key populated by the app bundle.
    public static let infoPlistKey = "AndBibleCloudKitContainerIdentifier"

    /// Concrete identifier accepted by SwiftData and `CKContainer`.
    public let value: String

    /**
     Validates one concrete CloudKit container identifier.

     - Parameter value: Identifier expected to start with `iCloud.` and contain no whitespace or
       unresolved build-setting syntax.
     - Throws: `ProductCloudKitContainerIdentifierError.invalidIdentifier` for malformed values.
     - Side effects: none.
     */
    public init(_ value: String) throws {
        let hasWhitespace = value.contains { $0.isWhitespace }
        guard value.hasPrefix("iCloud."),
              value.count > "iCloud.".count,
              !value.contains("$("),
              !hasWhitespace else {
            throw ProductCloudKitContainerIdentifierError.invalidIdentifier(value)
        }
        self.value = value
    }

    /**
     Resolves and validates the build-owned identifier from an Info.plist dictionary.

     - Parameter infoDictionary: Processed metadata for the AndBible app bundle.
     - Throws: A missing-value error when the key is absent or empty, or an invalid-identifier error
       when the value is not a concrete CloudKit container identifier.
     - Side effects: none.
     */
    public init(infoDictionary: [String: Any]?) throws {
        guard let value = infoDictionary?[Self.infoPlistKey] as? String,
              !value.isEmpty else {
            throw ProductCloudKitContainerIdentifierError.missingInfoPlistValue(
                key: Self.infoPlistKey
            )
        }
        try self.init(value)
    }

    /**
     Resolves the required identifier from an app bundle and stops startup on contract violations.

     - Parameter bundle: Built product bundle whose processed Info.plist owns the identifier.
     - Returns: Validated identifier for the current product.
     - Side effects: Reads bundle metadata.
     - Failure modes: Traps with a diagnostic when product metadata is missing or malformed, because
       silently selecting a fallback container could split one user's iCloud state.
     */
    public static func required(in bundle: Bundle) -> ProductCloudKitContainerIdentifier {
        do {
            return try ProductCloudKitContainerIdentifier(infoDictionary: bundle.infoDictionary)
        } catch {
            preconditionFailure("Invalid AndBible CloudKit container contract: \(error)")
        }
    }
}
