// SpeechVoiceResolver.swift -- Installed voice selection for Android-compatible speech

import AVFoundation
import Foundation

/**
 Describes one installed speech voice without exposing AVFoundation objects to selection tests.

 The identifier remains the stable lookup key while the BCP-47 language drives Android-compatible
 locale preference matching. Constructing a descriptor has no side effects and accepts the exact
 values reported by `AVSpeechSynthesisVoice`.
 */
struct SpeechVoiceDescriptor: Equatable, Sendable {
    /// Stable platform voice identifier used to recover the selected AVFoundation voice.
    let identifier: String

    /// BCP-47 language identifier advertised by the installed voice.
    let language: String

    /** Creates an immutable installed-voice descriptor. */
    init(identifier: String, language: String) {
        self.identifier = identifier
        self.language = language
    }
}

/** Resolves an installed platform voice for one requested document language. */
protocol SpeechVoiceResolving {
    /**
     Resolves a concrete installed voice without allowing AVFoundation to choose an unrelated one.

     - Parameters:
       - requestedLanguage: Module or document language, normally a BCP-47 identifier.
       - deviceLocale: Current device locale used by Android's same-language regional preference.
     - Returns: An installed voice matching the Android preference order, or `nil` when unsupported.
     - Side effects: Implementations may query the platform's installed speech-voice catalog.
     - Failure modes: Blank or too-short requests use Android's device-language fallback; valid but
       unsupported language codes return `nil` instead of selecting an unrelated platform default.
     */
    func resolveVoice(
        for requestedLanguage: String,
        deviceLocale: Locale
    ) -> AVSpeechSynthesisVoice?
}

/**
 Selects installed voices using AndBible Android's language and region precedence.

 Android first prefers the full device locale when the requested language matches the device
 language, then its known native-region mapping, then a base-language voice. Explicit regional
 requests are tried before those fallbacks. Ancient Greek (`grc`) maps to modern Greek (`el`).
 Selection is deterministic for a supplied ordered catalog and never crosses language families.
 */
enum SpeechVoiceResolution {
    /** One ordered language candidate and whether its base form may match any installed region. */
    private struct Candidate: Equatable {
        let identifier: String
        let permitsRegionalVoice: Bool
    }

    /// Android's `getDefaultCountryCode` mapping from language to preferred native region.
    private static let defaultRegions: [String: String] = [
        "en": "GB",
        "fr": "FR",
        "de": "DE",
        "zh": "CN",
        "it": "IT",
        "jp": "JP",
        "ko": "KR",
        "hu": "HU",
        "cs": "CZ",
        "fi": "FI",
        "pl": "PL",
        "pt": "PT",
        "ru": "RU",
        "tr": "TR",
    ]

    /**
     Returns the ordered language identifiers considered for a speech request.

     - Parameters:
       - requestedLanguage: Module or document language supplied by the active provider.
       - deviceLocale: Device locale used for same-language regional pronunciation.
     - Returns: Deduplicated normalized identifiers in resolution order.
     - Side effects: none.
     - Failure modes: Invalid requests rerun Android's device-language, native-region, and base
       fallback sequence; an invalid device locale produces an empty list.
     */
    static func preferredLanguageIdentifiers(
        requestedLanguage: String,
        deviceLocale: Locale
    ) -> [String] {
        candidates(
            requestedLanguage: requestedLanguage,
            deviceLocaleIdentifier: deviceLocale.identifier
        ).map(\.identifier)
    }

    /**
     Selects one installed voice identifier without permitting unrelated-language fallback.

     Exact regional candidates win first. Only the final base-language candidate may accept an
     installed regional variant, mirroring Android's `setLanguage(Locale(language))` behavior.

     - Parameters:
       - requestedLanguage: Module or document language supplied by the active provider.
       - deviceLocale: Device locale used for same-language regional pronunciation.
       - installedVoices: Installed voices in platform preference order.
     - Returns: Identifier of the selected installed voice, or `nil` when no candidate is present.
     - Side effects: none.
     - Failure modes: Invalid descriptors are ignored. Duplicate descriptors retain input order.
     */
    static func selectedVoiceIdentifier(
        requestedLanguage: String,
        deviceLocale: Locale,
        installedVoices: [SpeechVoiceDescriptor]
    ) -> String? {
        let normalizedVoices = installedVoices.compactMap { voice -> (SpeechVoiceDescriptor, String)? in
            guard let language = normalizedLanguageIdentifier(voice.language) else { return nil }
            return (voice, language)
        }

        for candidate in candidates(
            requestedLanguage: requestedLanguage,
            deviceLocaleIdentifier: deviceLocale.identifier
        ) {
            if let exact = normalizedVoices.first(where: { $0.1 == candidate.identifier }) {
                return exact.0.identifier
            }
            guard candidate.permitsRegionalVoice,
                  let candidateLanguage = primaryLanguage(in: candidate.identifier),
                  let regional = normalizedVoices.first(where: {
                      primaryLanguage(in: $0.1) == candidateLanguage
                  }) else {
                continue
            }
            return regional.0.identifier
        }
        return nil
    }

    /** Builds Android's ordered locale candidates and preserves base-language fallback semantics. */
    private static func candidates(
        requestedLanguage: String,
        deviceLocaleIdentifier: String
    ) -> [Candidate] {
        let deviceIdentifier = normalizedLanguageIdentifier(deviceLocaleIdentifier)
        let devicePrimary = deviceIdentifier.flatMap(primaryLanguage)
        let requestedIdentifier = normalizedLanguageIdentifier(requestedLanguage) ?? devicePrimary
        guard let requestedIdentifier,
              let requestedPrimary = primaryLanguage(in: requestedIdentifier) else { return [] }

        var values: [Candidate] = []
        if requestedIdentifier != requestedPrimary {
            values.append(Candidate(identifier: requestedIdentifier, permitsRegionalVoice: false))
            if let requestedRegion = languageAndRegionIdentifier(requestedIdentifier),
               requestedRegion != requestedIdentifier {
                values.append(Candidate(identifier: requestedRegion, permitsRegionalVoice: false))
            }
        }

        if let deviceIdentifier,
           devicePrimary == requestedPrimary {
            values.append(Candidate(identifier: deviceIdentifier, permitsRegionalVoice: false))
            if let deviceRegion = languageAndRegionIdentifier(deviceIdentifier),
               deviceRegion != deviceIdentifier {
                values.append(Candidate(identifier: deviceRegion, permitsRegionalVoice: false))
            }
        }

        let effectivePrimary = requestedPrimary == "grc" ? "el" : requestedPrimary
        if let region = defaultRegions[requestedPrimary] {
            values.append(
                Candidate(
                    identifier: "\(requestedPrimary)-\(region)",
                    permitsRegionalVoice: false
                )
            )
        }
        values.append(Candidate(identifier: effectivePrimary, permitsRegionalVoice: true))
        return deduplicatedCandidates(values)
    }

    /** Deduplicates candidate identifiers while retaining the strongest regional fallback flag. */
    private static func deduplicatedCandidates(_ candidates: [Candidate]) -> [Candidate] {
        var result: [Candidate] = []
        for candidate in candidates {
            if let index = result.firstIndex(where: { $0.identifier == candidate.identifier }) {
                if candidate.permitsRegionalVoice && !result[index].permitsRegionalVoice {
                    result[index] = candidate
                }
            } else {
                result.append(candidate)
            }
        }
        return result
    }

    /** Normalizes common BCP-47 casing and separators without inventing missing subtags. */
    private static func normalizedLanguageIdentifier(_ rawValue: String) -> String? {
        let withoutKeywords = rawValue.split(separator: "@", maxSplits: 1).first.map(String.init) ?? rawValue
        let components = withoutKeywords
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-", omittingEmptySubsequences: true)
            .map(String.init)
        guard let first = components.first, first.count >= 2 else { return nil }

        return components.enumerated().map { index, component in
            if index == 0 { return component.lowercased() }
            if component.count == 4 {
                return component.prefix(1).uppercased() + component.dropFirst().lowercased()
            }
            if component.count == 2 || component.allSatisfy(\.isNumber) {
                return component.uppercased()
            }
            return component.lowercased()
        }.joined(separator: "-")
    }

    /** Extracts the normalized primary language subtag from one candidate identifier. */
    private static func primaryLanguage(in identifier: String) -> String? {
        normalizedLanguageIdentifier(identifier)?.split(separator: "-").first.map(String.init)
    }

    /** Removes script and variant subtags while preserving a language's explicit region. */
    private static func languageAndRegionIdentifier(_ identifier: String) -> String? {
        guard let normalized = normalizedLanguageIdentifier(identifier) else { return nil }
        let components = normalized.split(separator: "-").map(String.init)
        guard let language = components.first,
              let region = components.dropFirst().first(where: {
                  $0.count == 2 || ($0.count == 3 && $0.allSatisfy(\.isNumber))
              }) else {
            return nil
        }
        return "\(language)-\(region)"
    }
}

/** Queries AVFoundation's installed voices and applies strict Android-compatible selection. */
struct SystemSpeechVoiceResolver: SpeechVoiceResolving {
    /**
     Resolves one installed AVFoundation voice from the current system catalog.

     - Parameters:
       - requestedLanguage: Module or document language supplied by the active provider.
       - deviceLocale: Device locale used for regional preference.
     - Returns: The selected installed voice, or `nil` when the language is unsupported.
     - Side effects: Reads the process-visible AVFoundation speech voice catalog.
     - Failure modes: Catalog changes between enumeration and lookup return `nil`; no unrelated
       platform default is accepted.
     */
    func resolveVoice(
        for requestedLanguage: String,
        deviceLocale: Locale
    ) -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let descriptors = voices.map {
            SpeechVoiceDescriptor(identifier: $0.identifier, language: $0.language)
        }
        guard let identifier = SpeechVoiceResolution.selectedVoiceIdentifier(
            requestedLanguage: requestedLanguage,
            deviceLocale: deviceLocale,
            installedVoices: descriptors
        ) else {
            return nil
        }
        return voices.first(where: { $0.identifier == identifier })
    }
}

/** User-observable speech failures that stop a provider before synthesis begins. */
public enum SpeakServiceFailure: Error, Equatable, LocalizedError, Sendable {
    /// No installed voice can speak the requested module or document language.
    case unsupportedLanguage(String)

    /** Android-parity status rendered by the existing speech status surface. */
    public var errorDescription: String? {
        switch self {
        case .unsupportedLanguage:
            return String(
                localized: "tts_lang_not_available",
                defaultValue: "Language is not available."
            )
        }
    }
}
