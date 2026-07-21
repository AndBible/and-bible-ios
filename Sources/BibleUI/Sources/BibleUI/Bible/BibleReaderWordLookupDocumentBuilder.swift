import Foundation
import BibleCore
import BibleView
import SwordKit

/**
 Builds Android-style selected-word dictionary `MultiDocument` payloads.

 `BibleReaderController` owns reader orchestration and bridge routing. This builder owns the
 selected-word lookup rules that Android implements in `LinkControl.lookupInDictionaries` and
 `SwordDocumentFacade.wordLookupDictionaries`: trim the selected text, remove trailing punctuation,
 search enabled plain dictionaries, and render successful matches as one transient multi-document.
 */
struct BibleReaderWordLookupDocumentBuilder {
    /// Supplies currently enabled dictionary modules for selected-word lookup.
    typealias DictionaryModulesProvider = () -> [DictionaryModule]

    /// Active dictionary module projection used by the builder without exposing SWORD to tests.
    struct DictionaryModule {
        /// Module initials used as Vue fragment document identity.
        let name: String

        /// Short module label shown in Vue tabs.
        let abbreviation: String

        /// Source SWORD versification, or `nil` for non-SWORD custom documents.
        let v11n: String?

        /// Source language code.
        let language: String

        /// Source reading direction.
        let direction: String

        /// Resolves the first matching dictionary key variant for this module.
        let lookup: ([String]) -> BibleReaderStrongsDocumentBuilder.DictionaryLookupResult?

        /**
         Creates a lightweight dictionary module projection.

         - Parameters:
           - name: SWORD module initials used for fragment identity.
           - abbreviation: User-facing short module label for tabs.
           - lookup: Closure that returns the exact dictionary entry for ordered key options.
         - Side effects: None during construction; the lookup closure may move a module cursor when
           invoked by `buildWordLookupMultiDocumentJSON(query:)`.
         - Failure modes: The lookup closure returns `nil` when no exact-enough key match exists.
         */
        init(
            name: String,
            abbreviation: String,
            v11n: String? = nil,
            language: String = "en",
            direction: String = "ltr",
            lookup: @escaping ([String]) -> BibleReaderStrongsDocumentBuilder.DictionaryLookupResult?
        ) {
            self.name = name
            self.abbreviation = abbreviation
            self.v11n = v11n
            self.language = language
            self.direction = direction
            self.lookup = lookup
        }
    }

    /// Deferred provider so preference changes and installed-module changes are observed per call.
    private let modules: DictionaryModulesProvider

    /**
     Creates a testable word-lookup builder from a module provider.

     - Parameter modules: Closure returning the currently enabled plain dictionary modules.
     - Side effects: None during construction.
     - Failure modes: An empty provider result makes availability false and payload creation return
       `nil`, matching Android's not-found behavior for missing lookup dictionaries.
     */
    init(modules: @escaping DictionaryModulesProvider) {
        self.modules = modules
    }

    /**
     Creates a production builder bound to SWORD and settings state.

     - Parameters:
       - swordManager: Active SWORD manager used to enumerate and resolve installed modules.
       - disabledDictionaryNames: Closure returning Android's inverse selected-word dictionary
         preference set, `disabled_word_lookup_dictionaries`.
     - Side effects: None during construction; module enumeration and SWORD cursor movement happen
       when availability or payload methods are called.
     - Failure modes: Missing SWORD returns no modules, producing the same user-facing not-found path
       as Android when no word lookup dictionaries are available.
     */
    init(
        swordManager: SwordManager?,
        disabledDictionaryNames: @escaping () -> Set<String>
    ) {
        self.modules = {
            guard let manager = swordManager else { return [] }
            let disabled = disabledDictionaryNames()
            return Self.wordLookupDictionaryModules(
                swordManager: manager,
                disabledDictionaryNames: disabled
            )
        }
    }

    /**
     Creates a production builder from Android's global SWORD/SQLite dictionary registry.

     - Parameters:
       - installedDictionarySources: Deferred globally resolved dictionary inventory.
       - disabledDictionaryNames: Deferred inverse selected-word preference set.
     - Side effects: None during construction; each availability/lookup call reads current
       preferences and invokes exact backend lookups on enabled sources.
     - Failure modes: Wrong-category, Strong's/morphology, disabled, and unreadable sources are
       omitted; an empty result follows the normal not-found path.
     */
    init(
        installedDictionarySources: @escaping () -> [BibleReaderInstalledDictionarySource],
        disabledDictionaryNames: @escaping () -> Set<String>
    ) {
        self.modules = {
            let disabled = disabledDictionaryNames()
            return installedDictionarySources().compactMap { source in
                let info = source.info
                guard info.category == .dictionary,
                      !info.features.contains(.greekDef),
                      !info.features.contains(.hebrewDef),
                      !info.features.contains(.greekParse),
                      !disabled.contains(info.name) else {
                    return nil
                }
                return Self.dictionaryModule(source)
            }
        }
    }

    /**
     Whether any enabled plain dictionary is available for selected-word lookup.

     - Returns: `true` when at least one installed plain dictionary is not disabled by preferences.
     - Side effects: Reads installed module metadata and the disabled-dictionary preference closure.
     - Failure modes: Missing SWORD or no enabled dictionaries returns `false`.
     */
    var hasWordLookupDictionaries: Bool {
        !modules().isEmpty
    }

    /**
     Normalizes selected text before dictionary lookup using Android's `normalizeSearchText` rules.

     Android trims whitespace and strips trailing punctuation before calling JSword `Book.getKey`.
     iOS applies the same text transform, then compensates for libsword case handling through ordered
     key variants during lookup.

     - Parameter text: Raw selected text from the web client.
     - Returns: Sanitized lookup key used against plain dictionary modules.
     - Side effects: None.
     - Failure modes: Whitespace-only or punctuation-only input returns an empty string.
     */
    static func normalizeQuery(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[.,;:!?"'()\[\]]+$"#, with: "", options: .regularExpression)
    }

    /**
     Builds a selected-word dictionary `MultiDocument` payload for Vue.

     - Parameter query: Normalized lookup key to resolve across enabled plain dictionaries.
     - Returns: Serialized bridge JSON for matching dictionary entries, or `nil` when no enabled
       dictionary contains the key.
     - Side effects: Reads enabled dictionary modules and invokes each lookup closure, which may move
       SWORD cursors.
     - Failure modes: Empty module sets, lookup misses, or JSON encoding failure return `nil` so the
       controller can show the existing Android-parity not-found toast.
     */
    func buildWordLookupMultiDocumentJSON(query: String) -> String? {
        let enabledModules = modules()
        guard !enabledModules.isEmpty else { return nil }

        let keyOptions = wordLookupKeyOptions(for: query)
        let escapedTitle = Self.escapeXML(query)
        var fragments: [BibleReaderMultiFragmentDocumentBuilder.Fragment] = []

        for module in enabledModules {
            guard let lookup = module.lookup(keyOptions) else { continue }
            let xml = lookup.isNativeHtml
                ? BibleReaderStrongsDocumentBuilder.buildDictionaryEntryHTML(renderedText: lookup.renderedText)
                : "<div><title type=\"x-gen\">\(escapedTitle)</title><div type=\"paragraph\">\(lookup.renderedText)</div></div>"
            fragments.append((
                xml: xml,
                key: "\(module.name)--\(query)",
                keyName: query,
                bookInitials: module.name,
                bookAbbreviation: module.abbreviation,
                v11n: module.v11n,
                language: module.language,
                direction: module.direction,
                features: OsisFeatures(),
                isNativeHtml: lookup.isNativeHtml
            ))
        }

        guard !fragments.isEmpty else { return nil }
        return BibleReaderMultiFragmentDocumentBuilder.buildJSON(fragments: fragments)
    }

    /**
     Projects installed SWORD modules into selected-word lookup dictionary modules.

     Android includes plain dictionary books and excludes Strong's Greek definitions, Strong's Hebrew
     definitions, and Greek morphology parsers. The disabled set is inverse selection state, so names
     present in the set are removed from the result.

     - Parameters:
       - swordManager: SWORD manager used to enumerate and resolve modules.
       - disabledDictionaryNames: Module initials disabled by the user.
     - Returns: Enabled plain dictionary modules in installed-module order.
     - Side effects: Reads SWORD installed-module metadata and resolves matching modules.
     - Failure modes: Modules that disappear between metadata enumeration and resolution are skipped.
     */
    private static func wordLookupDictionaryModules(
        swordManager: SwordManager,
        disabledDictionaryNames: Set<String>
    ) -> [DictionaryModule] {
        var result: [DictionaryModule] = []
        for info in swordManager.installedModules() where
            info.category == .dictionary &&
                !info.features.contains(.greekDef) &&
                !info.features.contains(.hebrewDef) &&
                !info.features.contains(.greekParse) &&
                !disabledDictionaryNames.contains(info.name) {
            guard let module = swordManager.module(named: info.name) else { continue }
            result.append(
                DictionaryModule(
                    name: module.info.name,
                    abbreviation: String(module.info.name.prefix(10)),
                    v11n: VersificationMapper.versificationName(for: module),
                    language: module.info.language.isEmpty ? "en" : module.info.language,
                    direction: module.info.isRightToLeft ? "rtl" : "ltr",
                    lookup: { keyOptions in
                        BibleReaderStrongsDocumentBuilder.lookupInModule(
                            module,
                            keyOptions: keyOptions
                        )
                    }
                )
            )
        }
        return result
    }

    /** Projects one globally resolved SWORD/SQLite dictionary into the lookup facade. */
    private static func dictionaryModule(
        _ source: BibleReaderInstalledDictionarySource
    ) -> DictionaryModule {
        DictionaryModule(
            name: source.info.name,
            abbreviation: source.abbreviation,
            v11n: source.versificationName,
            language: source.info.language.isEmpty ? "en" : source.info.language,
            direction: source.info.isRightToLeft ? "rtl" : "ltr",
            lookup: { source.lookup(keyOptions: $0) }
        )
    }

    /**
     Produces lookup key variants that compensate for libsword case sensitivity.

     Android delegates case normalization to JSword `Book.getKey`. SWORD on iOS can be stricter, so
     the builder tries the selected spelling, lowercase, and title-case forms while still requiring
     the shared dictionary lookup validator to confirm the resolved key.

     - Parameter query: Normalized selected-word lookup key.
     - Returns: Ordered key variants to try against each dictionary module.
     - Side effects: None.
     - Failure modes: Empty query returns empty variants.
     */
    private func wordLookupKeyOptions(for query: String) -> [String] {
        [query, query.lowercased(), query.capitalized]
    }

    /**
     Escapes XML-sensitive characters in generated title text.

     - Parameter text: Raw title text.
     - Returns: XML-safe text for insertion into generated OSIS fragment XML.
     - Side effects: None.
     - Failure modes: None; all input strings produce deterministic escaped output.
     */
    private static func escapeXML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
