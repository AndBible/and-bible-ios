// BibleReaderMultiFragmentDocumentBuilder.swift — Vue fragment assembly for definitions

import BibleView
import Foundation
import os.log

private let multiFragmentLogger = Logger(
    subsystem: "org.andbible",
    category: "BibleReaderMultiFragmentDocumentBuilder"
)

/** Encodes Vue multi-fragment document payloads used by Strong's and dictionary results. */
enum BibleReaderMultiFragmentDocumentBuilder {
    /// Fragment tuple used by existing controller and builder call sites.
    typealias Fragment = (
        xml: String,
        key: String,
        keyName: String,
        osisRef: String,
        bookCategory: String,
        bookInitials: String,
        bookAbbreviation: String,
        v11n: String?,
        language: String,
        direction: String,
        features: OsisFeatures,
        hasStrongs: Bool,
        isNativeHtml: Bool
    )

    /**
     Builds one typed `MultiFragmentDocumentPayload` JSON string for Vue.

     - Parameters:
       - fragments: Ordered Android definition fragments to serialize.
       - contentType: Optional aggregate content type such as `strongs`.
       - stateJSON: Optional opaque Vue state JSON to retain.
     - Returns: Encoded multi-document JSON, or nil when payload/state serialization fails.
     - Side effects: Generates one UUID and logs serialization failures.
     - Failure modes: Malformed state or JSON encoding returns nil without a partial payload.
     */
    static func buildJSON(
        fragments: [Fragment],
        contentType: String? = nil,
        stateJSON: String? = nil
    ) -> String? {
        let id = "strongs-multi-\(UUID().uuidString)"
        let osisFragments = fragments.map { fragment in
            OsisFragment(
                xml: fragment.xml.replacingOccurrences(of: "\r", with: ""),
                key: fragment.key,
                keyName: fragment.keyName,
                v11n: fragment.v11n,
                bookCategory: fragment.bookCategory,
                bookInitials: fragment.bookInitials,
                bookAbbreviation: fragment.bookAbbreviation,
                osisRef: fragment.osisRef,
                isNewTestament: false,
                features: fragment.features,
                hasStrongs: fragment.hasStrongs,
                ordinalRange: nil,
                language: fragment.language,
                direction: fragment.direction,
                isNativeHtml: fragment.isNativeHtml
            )
        }
        let payload = MultiFragmentDocumentPayload(
            id: id,
            type: "multi",
            osisFragments: osisFragments,
            compare: false,
            contentType: contentType,
            state: bridgeJSONValue(from: stateJSON)
        )
        guard let data = try? bridgeEncoder.encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            multiFragmentLogger.error("Failed to encode multi-fragment bridge document")
            return nil
        }
        return json
    }

    /**
     Parses an optional raw JSON state blob into a typed bridge JSON value.

     - Parameter json: Optional Vue state JSON retained by a previous document.
     - Returns: Typed bridge value, or nil for absent/malformed input.
     - Side effects: Logs malformed JSON.
     - Failure modes: Invalid UTF-8/JSON returns nil without throwing.
     */
    private static func bridgeJSONValue(from json: String?) -> BridgeJSONValue? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        do {
            let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return BridgeJSONValue(object)
        } catch {
            multiFragmentLogger.error(
                "Failed to parse saved bridge state JSON: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }
}
