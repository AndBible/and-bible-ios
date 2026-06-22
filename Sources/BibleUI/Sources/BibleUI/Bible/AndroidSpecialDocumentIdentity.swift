import Foundation
import BibleCore

/**
 Encodes Android fake-document identities that are not installed SWORD modules.

 Android represents links-window aggregate results with `FakeBookFactory.multiDocument`: a
 `GENERAL_BOOK` page whose document initials are `Multi` and whose key is a serialized
 `BookAndKeyList` OSIS reference string such as `KJV:Gen.1.1||KJV:John.3.16`. iOS uses this helper
 as the single native source for those constants, persisted-key derivation, and restored-key parsing.

 - Note: The helper is intentionally UI-target-local plumbing. It does not add iOS-only user-facing
   semantics; it maps iOS bridge payloads onto Android's existing fake-document contract.
 */
enum AndroidSpecialDocumentIdentity {
    /**
     One child entry from Android's persisted `BookAndKeyList.osisRef` string.

     `documentInitials == nil` mirrors Android's `null:` marker, which means "resolve against the
     current Bible document" during restore. The key is the child `Key.osisRef` value that should be
     handed back to the source document.
     */
    struct BookAndKeyReference {
        /// Source document initials, or `nil` for Android's `null` current-Bible marker.
        let documentInitials: String?

        /// Persisted key/OSIS reference for the source document.
        let key: String
    }

    /// Android `FakeBookFactory.multiDocument.initials`.
    static let multiDocumentInitials = "Multi"

    /// PageManager category Android uses for `FakeBookFactory.multiDocument`.
    static let multiDocumentCategory = DocumentCategory.generalBook

    /// Rendered-content token used to identify Strong's `MultiDocument` pages for Vue state replay.
    static let strongsRenderedKey = "strongs"

    /// Rendered-content token used for ordinary multi-reference `MultiDocument` pages.
    static let multiRenderedKey = "multi"

    /**
     Identifies whether a persisted or rendered page identity is Android's synthetic `Multi` document.

     - Parameters:
       - categoryName: PageManager-style category key such as `general_book`.
       - moduleName: Document/module initials associated with the page.
     - Returns: `true` only for Android's `general_book` + `Multi` fake-document pair.
     - Side effects: None.
     - Failure modes: Missing or differently-cased inputs return `false`; callers should preserve
       ordinary SWORD module behavior in that case.
     */
    static func isMultiDocument(categoryName: String?, moduleName: String?) -> Bool {
        categoryName == multiDocumentCategory.pageManagerKey && moduleName == multiDocumentInitials
    }

    /**
     Derives Android's `BookAndKeyList.osisRef` persistence string from a Vue `MultiDocument`.

     Each OSIS fragment stores the source document initials and fragment reference. Android persists
     a `BookAndKeyList` by joining each child `BookAndKey.osisRef` with `||`, where each child is
     `documentInitials:keyOsisRef` and `null` marks "use the current Bible". iOS fragments normally
     carry `bookInitials`, but the `null` fallback keeps the generated key compatible with Android's
     unspecified-document branch.

     - Parameter documentJSON: Serialized Vue `MultiDocument` payload emitted through the bridge.
     - Returns: Android-compatible `BookAndKeyList` OSIS reference, or `nil` when no fragment has a
       usable key.
     - Side effects: None.
     - Failure modes: Malformed JSON, a non-object root, missing fragment arrays, or fragments without
       keys return `nil`; callers may still render the transient document but should avoid overwriting
       persisted keys with an invalid value.
     */
    static func bookAndKeyListReference(from documentJSON: String) -> String? {
        guard let data = documentJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fragments = root["osisFragments"] as? [[String: Any]] else {
            return nil
        }

        let references = fragments.compactMap { fragment -> String? in
            guard let key = nonEmptyString(fragment["osisRef"])
                    ?? nonEmptyString(fragment["keyName"])
                    ?? nonEmptyString(fragment["key"]) else {
                return nil
            }
            let document = nonEmptyString(fragment["bookInitials"]) ?? "null"
            return "\(document):\(key)"
        }

        return references.isEmpty ? nil : references.joined(separator: "||")
    }

    /**
     Parses Android's persisted `BookAndKeyList.osisRef` value into document/key pairs.

     Android restores `FakeBookFactory.multiDocument` by splitting the saved key on `||`, then
     splitting each child on the first `:`. The string `null` is not a real module; it delegates the
     child key to the current Bible document. iOS follows that contract so restored links windows can
     rebuild the same aggregate document instead of preserving only the tab label.

     - Parameter reference: Persisted PageManager key for the synthetic `Multi` document.
     - Returns: Parsed child references in stored order. Invalid or empty children are omitted.
     - Side effects: None.
     - Failure modes: Missing, empty, or malformed strings return an empty array.
     */
    static func parseBookAndKeyListReference(_ reference: String?) -> [BookAndKeyReference] {
        guard let reference = nonEmptyString(reference) else { return [] }
        return reference
            .components(separatedBy: "||")
            .compactMap { component -> BookAndKeyReference? in
                let parts = component.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { return nil }
                let documentPart = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                let key = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { return nil }
                let document = documentPart == "null" || documentPart.isEmpty ? nil : documentPart
                return BookAndKeyReference(documentInitials: document, key: key)
            }
    }

    /**
     Converts a loosely typed JSON value into a non-empty trimmed string.

     - Parameter value: JSON field extracted from `JSONSerialization`.
     - Returns: Trimmed string when present and non-empty, otherwise `nil`.
     - Side effects: None.
     - Failure modes: Non-string values and whitespace-only strings return `nil`.
     */
    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
