// SpeakDivineNameCatalog.swift -- Android-sourced localized divine-name substitutions

import Foundation

/** One resolved pair of Android Speak divine-name arrays. */
public struct SpeakDivineNameArrays: Sendable, Equatable {
    /// Source words replaced while parsing a `divineName` OSIS element.
    public let original: [String]
    /// Replacement words paired by array index with `original`.
    public let replacement: [String]

    /** Creates one resolved array pair without changing its Android ordering. */
    public init(original: [String], replacement: [String]) {
        self.original = original
        self.replacement = replacement
    }

    /// Non-empty, index-aligned substitutions safe to apply during command synthesis.
    public var replacements: [String: String] {
        Dictionary(
            uniqueKeysWithValues: zip(original, replacement).compactMap { source, target in
                guard !source.isEmpty, !target.isEmpty else { return nil }
                return (source, target)
            }
        )
    }
}

/**
 Loads Android's localized Speak divine-name arrays from a pinned generated resource.

 Android selects resources from the source document's language, not the interface locale. Locale
 identifiers are therefore reduced to their language component, with Android's `iw`/`in` aliases
 normalized to `he`/`id`. Missing languages use Android's base arrays; entries whose locale file
 explicitly defines an empty array stay empty.

 Failure modes:
 - a missing or malformed generated resource is a packaging error and triggers a precondition
   failure instead of silently restoring the old English-only substitutions
 - unequal arrays apply only index-aligned pairs, matching the meaningful prefix while avoiding an
   out-of-range access for malformed upstream translations
 */
public enum SpeakDivineNameCatalog {
    private struct Entry: Decodable {
        let resourceQualifier: String
        let original: [String]
        let replacement: [String]
    }

    private struct Payload: Decodable {
        let schemaVersion: Int
        let sourceAndroidRes: String
        let `default`: Entry
        let languages: [String: Entry]
    }

    private static let payload: Payload = {
        guard let url = Bundle.module.url(
            forResource: "divine-name-replacements",
            withExtension: "json",
            subdirectory: "speak"
        ), let data = try? Data(contentsOf: url),
        let payload = try? JSONDecoder().decode(Payload.self, from: data),
        payload.schemaVersion == 1 else {
            preconditionFailure("Missing or malformed Android Speak divine-name catalog")
        }
        return payload
    }()

    /**
     Resolves Android's effective arrays for a source document language.

     - Parameter languageIdentifier: SWORD/BCP-47 source language, such as `fr` or `pt-BR`.
     - Returns: Locale arrays after Android-compatible language and base-resource fallback.
     - Side effects: Loads the generated package resource once on first access.
     - Failure modes: Invalid or unknown identifiers deliberately use Android's base arrays.
     */
    public static func arrays(for languageIdentifier: String) -> SpeakDivineNameArrays {
        let language = normalizedLanguage(languageIdentifier)
        let entry = payload.languages[language] ?? payload.default
        return SpeakDivineNameArrays(original: entry.original, replacement: entry.replacement)
    }

    /** Returns non-empty localized substitutions for one source document language. */
    public static func replacements(for languageIdentifier: String) -> [String: String] {
        arrays(for: languageIdentifier).replacements
    }

    private static func normalizedLanguage(_ identifier: String) -> String {
        let normalized = identifier
            .replacingOccurrences(of: "_", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let language = normalized.split(separator: "-", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        switch language {
        case "iw": return "he"
        case "in": return "id"
        default: return language
        }
    }
}
