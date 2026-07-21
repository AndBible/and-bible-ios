// ProductCloudKitContainerIdentifier.swift - Build-owned CloudKit container contract

import Foundation

/**
 Errors produced while resolving a product's CloudKit container identifier from bundle metadata.

 The app targets own the concrete value through an Info.plist build substitution. Keeping malformed
 or unresolved substitutions explicit prevents a product from silently opening another SKU's store.
 */
public enum ProductCloudKitContainerIdentifierError: Error, Equatable, Sendable {
    /// The processed Info.plist does not contain a non-empty string for the required metadata key.
    case missingInfoPlistValue(key: String)

    /// The processed value is not a concrete CloudKit container identifier.
    case invalidIdentifier(String)
}

/**
 Validated identifier for the CloudKit container owned by one installed product.

 The concrete identifier comes from the app target's processed Info.plist, not from BibleCore or a
 runtime flavor guess. The same value is injected into SwiftData and `SyncService`, which keeps the
 standard and Calculator products on intentionally separate CloudKit stores.
 */
public struct ProductCloudKitContainerIdentifier: Equatable, Hashable, Sendable {
    /// Info.plist key populated by each app target's build settings.
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

     - Parameter infoDictionary: Processed bundle metadata for an app product.
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
       silently selecting a fallback container could cross the standard/Calculator data boundary.
     */
    public static func required(in bundle: Bundle) -> ProductCloudKitContainerIdentifier {
        do {
            return try ProductCloudKitContainerIdentifier(infoDictionary: bundle.infoDictionary)
        } catch {
            preconditionFailure("Invalid product CloudKit container contract: \(error)")
        }
    }
}
