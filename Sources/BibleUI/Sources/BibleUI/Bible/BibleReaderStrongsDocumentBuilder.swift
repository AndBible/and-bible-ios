import Foundation
import BibleCore
import BibleView
import SwordKit
import os.log

private let strongsDocumentBuilderLogger = Logger(subsystem: "org.andbible", category: "BibleReaderStrongsDocumentBuilder")

/**
 Builds Android-style Strong's, morphology, and dictionary `MultiDocument` payloads.

 `BibleReaderController` owns reader orchestration and bridge routing; this builder owns the
 dictionary-document rules needed to produce the Vue payload. The rules here intentionally mirror the
 Android/JSword behavior iOS depends on for Strong's lookup key families, selected dictionary
 preferences, morphology module selection, and missing-dictionary fallback documents.
 */
struct BibleReaderStrongsDocumentBuilder {
    /// Reads a persisted string-set preference such as selected Strong's dictionary modules.
    typealias SelectedPreferenceValues = (AppPreferenceKey) -> [String]

    /// Resolves a localized string by key with a caller-provided default value.
    typealias LocalizedString = (_ key: String, _ defaultValue: String) -> String

    /// Active SWORD manager used to resolve installed dictionary and morphology modules.
    private let swordManager: SwordManager?

    /// Preference reader for Android-parity Strong's and morphology module selections.
    private let selectedPreferenceValues: SelectedPreferenceValues

    /// User-visible module label projection used by Vue tabs.
    private let moduleDisplayLabel: (SwordModule) -> String

    /// Localized string lookup used for synthetic fallback documents.
    private let localizedString: LocalizedString

    /**
     Creates a Strong's document builder with explicit dependencies.

     - Parameters:
       - swordManager: Active SWORD manager for installed module discovery.
       - selectedPreferenceValues: Preference lookup for selected dictionary/morphology modules.
       - moduleDisplayLabel: Display-label projection for SWORD modules.
       - localizedString: Localization lookup with default-value fallback.
     - Side effects: None during construction.
     - Failure modes: Missing SWORD or preferences are handled by payload-building methods.
     */
    init(
        swordManager: SwordManager?,
        selectedPreferenceValues: @escaping SelectedPreferenceValues,
        moduleDisplayLabel: @escaping (SwordModule) -> String = Self.moduleDisplayLabel,
        localizedString: @escaping LocalizedString = { key, defaultValue in
            Bundle.main.localizedString(forKey: key, value: defaultValue, table: nil)
        }
    ) {
        self.swordManager = swordManager
        self.selectedPreferenceValues = selectedPreferenceValues
        self.moduleDisplayLabel = moduleDisplayLabel
        self.localizedString = localizedString
    }

    /**
     Builds a Vue `MultiDocument` payload from Strong's numbers and Robinson morphology codes.

     Android opens these results as a special `Multi` general-book document with
     `contentType: "strongs"`. iOS preserves that shape so dictionary tabs, recursive Strong's
     links, missing-dictionary fallbacks, and links-window identity stay aligned with Android.

     - Parameters:
       - strongs: Strong's numbers parsed from `ab-w://` query items.
       - robinson: Morphology codes parsed from `ab-w://` query items.
       - stateJSON: Optional opaque Vue state to restore into the result document.
     - Returns: Serialized Vue `MultiDocument` JSON, or `nil` when no content or fallback exists.
     - Side effects: Reads installed SWORD modules and temporarily moves dictionary cursors.
     - Failure modes: Missing dictionaries produce the Android-style download fallback for Strong's
       links. Missing morphology definitions are skipped.
     */
    func buildStrongsMultiDocumentJSON(strongs: [String], robinson: [String], stateJSON: String? = nil) -> String? {
        strongsDocumentBuilderLogger.info(
            "buildStrongsMultiDocumentJSON: strongs=\(strongs), robinson=\(robinson), swordManager=\(self.swordManager == nil ? "nil" : "alive")"
        )
        var fragments: [BibleReaderMultiFragmentDocumentBuilder.Fragment] = []

        for num in strongs {
            let lexModules = findAllLexiconModules(for: num)
            strongsDocumentBuilderLogger.info("buildStrongsMultiDocumentJSON: num=\(num), lexModules=\(lexModules.map { $0.info.name })")
            let keyOptions = Self.strongsLookupKeyOptions(for: num)
            strongsDocumentBuilderLogger.info("buildStrongsMultiDocumentJSON: keyOptions=\(keyOptions)")
            for mod in lexModules {
                if let lookup = Self.lookupInModule(mod, keyOptions: keyOptions) {
                    let isHebrew = num.hasPrefix("H") || (!num.hasPrefix("G") && (Int(String(num.drop(while: { $0.isLetter || $0 == "0" }))) ?? 0) > 5624)
                    let featureType = isHebrew ? "hebrew" : "greek"
                    let keyName = Self.canonicalStrongsKeyName(requested: num, actualKey: lookup.actualKey, rawEntry: lookup.rawEntry)
                    let xml = Self.buildDictionaryEntryXML(
                        rawEntry: lookup.rawEntry,
                        renderedText: lookup.renderedText,
                        strongsLinkPrefix: Self.strongsLinkPrefix(for: num)
                    )
                    let features = OsisFeatures(type: featureType, keyName: keyName)

                    fragments.append((
                        xml: xml,
                        key: "\(mod.info.name)--\(keyName)",
                        keyName: keyName,
                        bookInitials: mod.info.name,
                        bookAbbreviation: moduleDisplayLabel(mod),
                        features: features
                    ))
                }
            }
        }

        if !robinson.isEmpty {
            let morphModules = findMorphologyModules()
            for code in robinson {
                for mod in morphModules {
                    let morphKeys = [code, code.uppercased(), code.lowercased()]
                    if let lookup = Self.lookupInModule(mod, keyOptions: morphKeys) {
                        let xml = Self.buildDictionaryEntryXML(
                            rawEntry: lookup.rawEntry,
                            renderedText: lookup.renderedText,
                            fallbackTitle: "Morphology: \(code)"
                        )
                        fragments.append((
                            xml: xml,
                            key: "\(mod.info.name)--\(code)",
                            keyName: code,
                            bookInitials: mod.info.name,
                            bookAbbreviation: moduleDisplayLabel(mod),
                            features: OsisFeatures()
                        ))
                    }
                }
            }
        }

        if fragments.isEmpty, let firstStrongs = strongs.first {
            fragments.append(missingStrongsDictionaryFragment(for: firstStrongs))
        }

        if fragments.isEmpty {
            strongsDocumentBuilderLogger.info("buildStrongsMultiDocumentJSON: no definitions found")
            return nil
        }

        return BibleReaderMultiFragmentDocumentBuilder.buildJSON(
            fragments: fragments,
            contentType: "strongs",
            stateJSON: stateJSON
        )
    }

    /**
     Builds the Android-style missing-document fallback for unavailable Strong's dictionaries.

     - Parameter strongsNumber: Strong's number whose dictionary module could not be resolved.
     - Returns: A synthetic dictionary fragment with a Downloads link.
     - Side effects: Reads localized strings through the injected localization closure.
     - Failure modes: Empty or malformed numbers still produce a deterministic fallback key.
     */
    private func missingStrongsDictionaryFragment(
        for strongsNumber: String
    ) -> BibleReaderMultiFragmentDocumentBuilder.Fragment {
        let isHebrew = Self.isHebrewStrongsNumber(strongsNumber)
        let moduleName = isHebrew ? "StrongsHebrew" : "StrongsGreek"
        let featureType = isHebrew ? "hebrew" : "greek"
        let numericKey = Self.normalizeNumericKey(strongsNumber)
        let keyName = numericKey.count < 5
            ? String(repeating: "0", count: max(0, 5 - numericKey.count)) + numericKey
            : numericKey
        let message = Self.escapeXML(
            localizedString(
                "no_dictionary_installed",
                "No dictionary module installed. Download Strong's Hebrew/Greek from Downloads."
            )
        )
        let downloadsLabel = Self.escapeXML(
            localizedString(
                "downloads",
                "Downloads"
            )
        )
        let xml = """
        <div>
        <title type="x-gen">\(message)</title>
        <p><a href="download://">\(downloadsLabel)</a></p>
        </div>
        """
        return (
            xml: xml,
            key: "\(moduleName)--\(keyName)--missing",
            keyName: keyName,
            bookInitials: moduleName,
            bookAbbreviation: moduleName,
            features: OsisFeatures(type: featureType, keyName: keyName)
        )
    }

    /**
     Returns Strong's key variants using the same families Android tries for dictionary lookup.

     Android parity matters here because installed Strong's dictionaries do not all expose the same
     key shape. Some expect zero-padded numeric keys, some want a prefixed category key such as
     `G1234` / `H1234`, and some zLD modules require a trailing carriage return.
     */
    static func strongsLookupKeyOptions(for strongsNumber: String) -> [String] {
        let original = strongsNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let numberOnly = String(original.drop(while: { $0.isLetter }))
        let stripped = numberOnly.replacingOccurrences(of: "^0+", with: "", options: .regularExpression)
        let sanitizedBase = stripped.isEmpty ? numberOnly : stripped

        let categoryPrefix = isHebrewStrongsNumber(original) ? "H" : "G"

        var keys: [String] = []

        func appendUnique(_ candidate: String) {
            guard !candidate.isEmpty, !keys.contains(candidate) else { return }
            keys.append(candidate)
        }

        var digitVariants: [String] = [numberOnly]
        var currentDigits = numberOnly
        while currentDigits.hasPrefix("0"), currentDigits.count > 1 {
            currentDigits.removeFirst()
            digitVariants.append(currentDigits)
        }

        appendUnique(original)
        for digits in digitVariants {
            appendUnique(digits)
            appendUnique(digits + "\r")
            appendUnique("\(categoryPrefix)\(digits)")
        }
        appendUnique(sanitizedBase)

        return keys
    }

    /**
     Mirrors Android's heuristic for inferring Hebrew-vs-Greek when the prefix is omitted.
     */
    static func isHebrewStrongsNumber(_ strongsNumber: String) -> Bool {
        let normalized = strongsNumber.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if normalized.hasPrefix("H") { return true }
        if normalized.hasPrefix("G") { return false }

        let digits = String(normalized.drop(while: { $0.isLetter || $0 == "0" }))
        return (Int(digits) ?? 0) > 5624
    }

    /**
     Result of an exact-enough dictionary lookup.
     */
    struct DictionaryLookupResult {
        /// Key SWORD reported after positioning the module.
        let actualKey: String
        /// Raw entry XML/text for the matched key.
        let rawEntry: String
        /// SWORD-rendered text for the matched key.
        let renderedText: String
    }

    /**
     Tries each key variant in a module and returns the first valid render result.

     SWORD positions to the nearest entry when a key is absent, so the resolved key, raw entry, and
     rendered text are all validated before accepting a candidate.
     */
    static func lookupInModule(_ module: SwordModule, keyOptions: [String]) -> DictionaryLookupResult? {
        strongsDocumentBuilderLogger.info("lookupInModule: \(module.info.name), keyOptions=\(keyOptions)")

        for key in keyOptions {
            let inspection = module.setKeyAndInspect(key)
            let actualKey = inspection.actualKey
            let candidate = inspection.renderedText
            let trimmedKey = actualKey.trimmingCharacters(in: .whitespacesAndNewlines)
            strongsDocumentBuilderLogger.info("lookupInModule: tried key='\(key)', actualKey='\(trimmedKey)', renderLen=\(candidate.count)")

            switch dictionaryLookupCandidateRejectionReason(
                requested: key,
                actualKey: trimmedKey,
                rawEntry: inspection.rawEntry,
                renderedText: candidate
            ) {
            case .none:
                break
            case .actualKeyMismatch:
                strongsDocumentBuilderLogger.info("lookupInModule: key mismatch, skipping")
                continue
            case let .rawEntryMismatch(rawEntryKey):
                strongsDocumentBuilderLogger.info("lookupInModule: raw entry key mismatch (\(rawEntryKey)), skipping")
                continue
            case .emptyRenderedText:
                continue
            case .renderedEntryMismatch:
                strongsDocumentBuilderLogger.info("lookupInModule: rendered entry key mismatch, skipping")
                continue
            case .renderedTextMissingRequestedNumericKey:
                strongsDocumentBuilderLogger.info("lookupInModule: rendered text missing requested numeric key, skipping")
                continue
            }

            return DictionaryLookupResult(
                actualKey: trimmedKey,
                rawEntry: inspection.rawEntry.trimmingCharacters(in: .whitespacesAndNewlines),
                renderedText: candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return nil
    }

    /**
     Builds dictionary-entry XML suitable for the Vue OSIS fragment renderer.
     */
    static func buildDictionaryEntryXML(
        rawEntry: String,
        renderedText: String,
        fallbackTitle: String? = nil,
        strongsLinkPrefix: String? = nil
    ) -> String {
        let trimmedRawEntry = rawEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedRawEntry.hasPrefix("<"), trimmedRawEntry.hasSuffix(">") {
            let linkifiedRawEntry = linkifyRawDictionaryXML(
                trimmedRawEntry,
                defaultPrefix: strongsLinkPrefix
            )
            if let fallbackTitle, !trimmedRawEntry.localizedCaseInsensitiveContains("<title") {
                let escapedTitle = escapeXML(fallbackTitle)
                return "<div><title type=\"x-gen\">\(escapedTitle)</title>\(linkifiedRawEntry)</div>"
            }
            return "<div>\(linkifiedRawEntry)</div>"
        }

        let linkifiedHtml = linkifyRenderedDictionaryHTML(
            renderedText,
            defaultPrefix: strongsLinkPrefix
        )
        let titlePrefix = fallbackTitle.map { "<title type=\"x-gen\">\(escapeXML($0))</title>" } ?? ""
        return "<div>\(titlePrefix)<div type=\"paragraph\">\(linkifiedHtml)</div></div>"
    }

    /**
     Returns the Strong's prefix embedded in a key value.
     */
    static func strongsLinkPrefix(for value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let prefix = trimmed.first, prefix == "H" || prefix == "G" else {
            return nil
        }
        return String(prefix)
    }

    /**
     Returns the Strong's prefix implied by a curated dictionary module name.
     */
    static func strongsLinkPrefix(forModuleName moduleName: String) -> String? {
        switch moduleName {
        case "StrongsHebrew", "BDB", "OSHB":
            return "H"
        case "StrongsGreek", "StrongsRealGreek", "Thayer":
            return "G"
        default:
            return nil
        }
    }

    /**
     Produces the canonical five-digit Strong's key name used by Vue fragments.
     */
    static func canonicalStrongsKeyName(requested: String, actualKey: String, rawEntry: String) -> String {
        let resolvedKey = dictionaryEntryKey(actualKey: actualKey, rawEntry: rawEntry) ?? requested
        let numericKey = normalizeNumericKey(resolvedKey)
        guard !numericKey.isEmpty else {
            return normalizeNumericKey(requested)
        }
        return numericKey.count < 5
            ? String(repeating: "0", count: 5 - numericKey.count) + numericKey
            : numericKey
    }

    /**
     Extracts the dictionary entry key from SWORD current-key or raw XML metadata.
     */
    static func dictionaryEntryKey(actualKey: String, rawEntry: String) -> String? {
        let trimmedActualKey = actualKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedActualKey.isEmpty {
            return trimmedActualKey
        }

        let titlePattern = try? NSRegularExpression(pattern: #"<title>([^<]+)</title>"#, options: [])
        if let regex = titlePattern,
           let match = regex.firstMatch(in: rawEntry, range: NSRange(rawEntry.startIndex..., in: rawEntry)),
           let range = Range(match.range(at: 1), in: rawEntry) {
            return String(rawEntry[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let entryPattern = try? NSRegularExpression(
            pattern: #"<entryFree\b[^>]*\bn\s*=\s*"([^"]+)""#,
            options: []
        )
        if let regex = entryPattern,
           let match = regex.firstMatch(in: rawEntry, range: NSRange(rawEntry.startIndex..., in: rawEntry)),
           let range = Range(match.range(at: 1), in: rawEntry) {
            return String(rawEntry[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }

    /**
     Validates that a raw dictionary entry still refers to the requested lookup key.
     */
    static func rawDictionaryEntryMatchesRequestedKey(requested: String, rawEntry: String) -> Bool {
        guard let resolvedKey = dictionaryEntryKey(actualKey: "", rawEntry: rawEntry) else {
            return true
        }

        let trimmedRequested = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedResolvedKey = resolvedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedRequested.caseInsensitiveCompare(trimmedResolvedKey) == .orderedSame {
            return true
        }

        let requestedNumeric = normalizeNumericKey(trimmedRequested)
        let resolvedNumeric = normalizeNumericKey(trimmedResolvedKey)
        return !requestedNumeric.isEmpty && requestedNumeric == resolvedNumeric
    }

    /**
     Reason a candidate SWORD dictionary lookup was rejected.
     */
    enum DictionaryLookupCandidateRejectionReason: Equatable {
        /// SWORD reported a current key that does not match the requested key family.
        case actualKeyMismatch
        /// Raw entry metadata identifies a different dictionary key.
        case rawEntryMismatch(String)
        /// Rendered text is empty or a known missing-entry placeholder.
        case emptyRenderedText
        /// Rendered text begins with a different dictionary headword.
        case renderedEntryMismatch
        /// Modules without current-key support did not render the requested numeric key.
        case renderedTextMissingRequestedNumericKey
    }

    /**
     Validates one rendered dictionary lookup candidate.
     */
    static func dictionaryLookupCandidateRejectionReason(
        requested: String,
        actualKey: String,
        rawEntry: String,
        renderedText: String
    ) -> DictionaryLookupCandidateRejectionReason? {
        let trimmedActualKey = actualKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRenderedText = renderedText.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmedActualKey.isEmpty,
           !keysMatchNormalized(requested: requested, actual: trimmedActualKey) {
            return .actualKeyMismatch
        }

        if let rawEntryKey = dictionaryEntryKey(actualKey: "", rawEntry: rawEntry),
           !rawDictionaryEntryMatchesRequestedKey(requested: requested, rawEntry: rawEntry) {
            return .rawEntryMismatch(rawEntryKey)
        }

        if trimmedRenderedText.isEmpty || trimmedRenderedText.contains("@@@@") {
            return .emptyRenderedText
        }

        if !renderedDictionaryEntryMatchesRequestedKey(
            requested: requested,
            renderedText: trimmedRenderedText
        ) {
            return .renderedEntryMismatch
        }

        if trimmedActualKey.isEmpty {
            let numericKey = normalizeNumericKey(requested)
            if !numericKey.isEmpty && !trimmedRenderedText.contains(numericKey) {
                return .renderedTextMissingRequestedNumericKey
            }
        }

        return nil
    }

    /**
     Extracts a leading rendered dictionary headword from HTML/text content.
     */
    static func renderedDictionaryEntryKey(renderedText: String) -> String? {
        let withoutTags = renderedText.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: " ",
            options: .regularExpression
        )
        let normalized = withoutTags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else { return nil }

        let pattern = try? NSRegularExpression(
            pattern: #"^([HG]?\d{1,5})\b"#,
            options: [.caseInsensitive]
        )
        guard let regex = pattern,
              let match = regex.firstMatch(
                in: normalized,
                range: NSRange(normalized.startIndex..., in: normalized)
              ),
              let range = Range(match.range(at: 1), in: normalized) else {
            return nil
        }

        return String(normalized[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /**
     Validates that rendered dictionary content still belongs to the requested key.
     */
    static func renderedDictionaryEntryMatchesRequestedKey(requested: String, renderedText: String) -> Bool {
        guard let resolvedKey = renderedDictionaryEntryKey(renderedText: renderedText) else {
            return true
        }

        let trimmedRequested = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedResolvedKey = resolvedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedRequested.caseInsensitiveCompare(trimmedResolvedKey) == .orderedSame {
            return true
        }

        let requestedNumeric = normalizeNumericKey(trimmedRequested)
        let resolvedNumeric = normalizeNumericKey(trimmedResolvedKey)
        return !requestedNumeric.isEmpty && requestedNumeric == resolvedNumeric
    }

    /**
     Compares dictionary keys after stripping prefixes and leading zeros.
     */
    static func keysMatchNormalized(requested: String, actual: String) -> Bool {
        let trimmedRequested = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedActual = actual.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedRequested.caseInsensitiveCompare(trimmedActual) == .orderedSame { return true }

        let reqNumeric = normalizeNumericKey(trimmedRequested)
        let actNumeric = normalizeNumericKey(trimmedActual)
        if !reqNumeric.isEmpty && reqNumeric == actNumeric { return true }

        return false
    }

    /**
     Strips optional letter prefix and leading zeros from a numeric dictionary key.
     */
    static func normalizeNumericKey(_ key: String) -> String {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let afterLetters = String(trimmedKey.drop(while: { $0.isLetter }))
        let stripped = afterLetters.replacingOccurrences(of: "^0+", with: "", options: .regularExpression)
        guard !stripped.isEmpty, stripped.allSatisfy({ $0.isNumber }) else { return "" }
        return stripped
    }

    /**
     Returns a user-facing short label for a SWORD module.
     */
    static func moduleDisplayLabel(_ module: SwordModule) -> String {
        if let abbreviation = module.configEntry("Abbreviation")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !abbreviation.isEmpty {
            return abbreviation
        }
        return module.info.name
    }

    /**
     Mirrors Android's curated Strong's dictionary module policy.
     */
    static func isSupportedStrongsDictionaryModuleName(_ name: String) -> Bool {
        StrongsDictionaryPolicy.isSupportedDictionaryModuleName(name)
    }

    /**
     Finds all dictionary/glossary modules that can look up a given Strong's number.
     */
    private func findAllLexiconModules(for strongsNumber: String) -> [SwordModule] {
        guard let mgr = swordManager else {
            strongsDocumentBuilderLogger.error("findAllLexiconModules: swordManager is nil")
            return []
        }

        let isHebrew = Self.isHebrewStrongsNumber(strongsNumber)
        let feature: ModuleFeatures = isHebrew ? .hebrewDef : .greekDef

        let allModules = mgr.installedModules()
        strongsDocumentBuilderLogger.info("findAllLexiconModules: \(allModules.count) installed modules, isHebrew=\(isHebrew)")
        var result: [SwordModule] = []
        var seen = Set<String>()

        let selectionKey: AppPreferenceKey = isHebrew ? .strongsHebrewDictionary : .strongsGreekDictionary
        let selectedNames = selectedPreferenceValues(selectionKey)
        if !selectedNames.isEmpty {
            for name in selectedNames where seen.insert(name).inserted {
                if let mod = mgr.module(named: name),
                   StrongsDictionaryPolicy.isSupportedDictionaryModuleName(mod.info.name),
                   (mod.info.category == .dictionary || mod.info.category == .glossary),
                   mod.info.features.contains(feature) {
                    result.append(mod)
                }
            }
            if !result.isEmpty {
                return result
            }
        }

        for info in allModules where
            (info.category == .dictionary || info.category == .glossary) &&
                StrongsDictionaryPolicy.isSupportedDictionaryModuleName(info.name) &&
                info.features.contains(feature) {
            if seen.insert(info.name).inserted, let mod = mgr.module(named: info.name) {
                result.append(mod)
            }
        }

        if !result.isEmpty {
            return result
        }

        let lexiconNames = isHebrew
            ? ["StrongsHebrew", "OSHB", "BDB"]
            : ["StrongsGreek", "StrongsRealGreek", "Thayer", "ISBE"]
        for name in lexiconNames {
            if seen.insert(name).inserted, let mod = mgr.module(named: name) {
                result.append(mod)
            }
        }

        return result
    }

    /**
     Finds installed morphology dictionaries using Android's selected-first fallback order.
     */
    private func findMorphologyModules() -> [SwordModule] {
        guard let mgr = swordManager else { return [] }
        let allModules = mgr.installedModules()
        var result: [SwordModule] = []
        var seen = Set<String>()

        let selectedNames = selectedPreferenceValues(.robinsonGreekMorphology)
        if !selectedNames.isEmpty {
            for name in selectedNames where seen.insert(name).inserted {
                if let mod = mgr.module(named: name),
                   (mod.info.category == .dictionary || mod.info.category == .glossary),
                   mod.info.features.contains(.greekParse) {
                    result.append(mod)
                }
            }
            if !result.isEmpty {
                return result
            }
        }

        for info in allModules where
            (info.category == .dictionary || info.category == .glossary) &&
                info.features.contains(.greekParse) {
            if seen.insert(info.name).inserted, let mod = mgr.module(named: info.name) {
                result.append(mod)
            }
        }

        if !result.isEmpty {
            return result
        }

        for name in ["Robinson"] {
            if seen.insert(name).inserted, let mod = mgr.module(named: name) {
                result.append(mod)
            }
        }

        return result
    }

    /**
     Transforms dictionary cross-references into clickable Strong's links.
     */
    static func linkifyRenderedDictionaryHTML(_ html: String, defaultPrefix: String? = nil) -> String {
        var result = html

        result = linkifyStructuredDictionaryRefs(in: result, defaultPrefix: defaultPrefix)

        let bareRefPattern = try? NSRegularExpression(
            pattern: #"<ref\s+target="[^"]*?/?(\d+)"[^>]*>(.*?)</ref>"#,
            options: [.dotMatchesLineSeparators]
        )
        if let regex = bareRefPattern {
            let range = NSRange(result.startIndex..., in: result)
            let prefix = defaultPrefix.map { "\($0)" } ?? ""
            result = regex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: "<a href=\"ab-w://?strong=\(prefix)$1\">$2</a>"
            )
        }

        let seeHebrewPattern = try? NSRegularExpression(
            pattern: #"see HEBREW for (\d{4,5})"#,
            options: []
        )
        if let regex = seeHebrewPattern {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "see HEBREW for <a href=\"ab-w://?strong=H$1\">$1</a>")
        }

        let seeGreekPattern = try? NSRegularExpression(
            pattern: #"see GREEK for (\d{4,5})"#,
            options: []
        )
        if let regex = seeGreekPattern {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "see GREEK for <a href=\"ab-w://?strong=G$1\">$1</a>")
        }

        let fromPattern = try? NSRegularExpression(
            pattern: #"(?<=[Ff]rom )(\d{4,5})(?=[;,.\s]|$)"#,
            options: []
        )
        if let regex = fromPattern, let defaultPrefix {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: "<a href=\"ab-w://?strong=\(defaultPrefix)$1\">$1</a>"
            )
        }

        let brBeforeSensePattern = try? NSRegularExpression(
            pattern: #"<br\s*/?>\s*(?=<span\s+class="sense")"#,
            options: []
        )
        if let regex = brBeforeSensePattern {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }

        return result
    }

    /**
     Transforms raw dictionary XML references into clickable Strong's links.
     */
    static func linkifyRawDictionaryXML(_ xml: String, defaultPrefix: String? = nil) -> String {
        var result = xml

        result = linkifyStructuredDictionaryRefs(in: result, defaultPrefix: defaultPrefix)

        let bareRefPattern = try? NSRegularExpression(
            pattern: #"<ref\s+target="[^"]*?/?(\d+)"[^>]*>(.*?)</ref>"#,
            options: [.dotMatchesLineSeparators]
        )
        if let regex = bareRefPattern {
            let range = NSRange(result.startIndex..., in: result)
            let prefix = defaultPrefix.map { "\($0)" } ?? ""
            result = regex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: "<a href=\"ab-w://?strong=\(prefix)$1\">$2</a>"
            )
        }

        let seeHebrewPattern = try? NSRegularExpression(
            pattern: #"see HEBREW for (\d{4,5})"#,
            options: []
        )
        if let regex = seeHebrewPattern {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: "see HEBREW for <a href=\"ab-w://?strong=H$1\">$1</a>"
            )
        }

        let seeGreekPattern = try? NSRegularExpression(
            pattern: #"see GREEK for (\d{4,5})"#,
            options: []
        )
        if let regex = seeGreekPattern {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: "see GREEK for <a href=\"ab-w://?strong=G$1\">$1</a>"
            )
        }

        let fromPattern = try? NSRegularExpression(
            pattern: #"(?<=[Ff]rom )(\d{4,5})(?=[;,.\s]|$)"#,
            options: []
        )
        if let regex = fromPattern, let defaultPrefix {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: "<a href=\"ab-w://?strong=\(defaultPrefix)$1\">$1</a>"
            )
        }

        return result
    }

    /**
     Linkifies structured Strong's references in a dictionary fragment.
     */
    private static func linkifyStructuredDictionaryRefs(in source: String, defaultPrefix: String?) -> String {
        let refPattern = try? NSRegularExpression(
            pattern: #"<ref\s+target="(StrongsHebrew|StrongsGreek|StrongsRealGreek|BDB|OSHB|Thayer)[/:](\d+)"[^>]*>(.*?)</ref>"#,
            options: [.dotMatchesLineSeparators]
        )
        guard let regex = refPattern else { return source }

        let mutable = NSMutableString(string: source)
        let matches = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
        guard !matches.isEmpty else { return source }

        let nsSource = source as NSString
        for match in matches.reversed() {
            let moduleName = nsSource.substring(with: match.range(at: 1))
            let digits = nsSource.substring(with: match.range(at: 2))
            let text = nsSource.substring(with: match.range(at: 3))
            let prefix = strongsLinkPrefix(forModuleName: moduleName) ?? defaultPrefix ?? ""
            let replacement = "<a href=\"ab-w://?strong=\(prefix)\(digits)\">\(text)</a>"
            mutable.replaceCharacters(in: match.range, with: replacement)
        }

        return mutable as String
    }

    /**
     Escapes text content for XML fragments.
     */
    private static func escapeXML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/**
 Encodes Vue multi-fragment document payloads used by Strong's and dictionary results.
 */
enum BibleReaderMultiFragmentDocumentBuilder {
    /// Fragment tuple used by existing controller and builder call sites.
    typealias Fragment = (
        xml: String,
        key: String,
        keyName: String,
        bookInitials: String,
        bookAbbreviation: String,
        features: OsisFeatures
    )

    /**
     Builds a typed `MultiFragmentDocumentPayload` JSON string for Vue.
     */
    static func buildJSON(
        fragments: [Fragment],
        contentType: String? = nil,
        stateJSON: String? = nil
    ) -> String? {
        let id = "strongs-multi-\(UUID().uuidString)"
        let osisFragments = fragments.map { frag in
            OsisFragment(
                xml: frag.xml.replacingOccurrences(of: "\r", with: ""),
                key: frag.key,
                keyName: frag.keyName,
                v11n: "KJVA",
                bookCategory: DocumentCategory.dictionary.rawValue,
                bookInitials: frag.bookInitials,
                bookAbbreviation: frag.bookAbbreviation,
                osisRef: frag.keyName,
                isNewTestament: false,
                features: frag.features,
                hasStrongs: frag.features.type != nil,
                ordinalRange: [0, 0],
                language: "en",
                direction: "ltr"
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
            strongsDocumentBuilderLogger.error("Failed to encode multi-fragment bridge document")
            return nil
        }
        return json
    }

    /**
     Parses an optional raw JSON state blob into a typed bridge JSON value.
     */
    private static func bridgeJSONValue(from json: String?) -> BridgeJSONValue? {
        guard let json,
              let data = json.data(using: .utf8) else { return nil }
        do {
            let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return BridgeJSONValue(object)
        } catch {
            strongsDocumentBuilderLogger.error("Failed to parse saved bridge state JSON: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
