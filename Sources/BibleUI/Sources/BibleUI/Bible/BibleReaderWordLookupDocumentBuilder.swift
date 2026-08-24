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

 - Side effects: Reads the deferred installed/preference inventory, performs one backend key lookup
   per enabled source, and serializes actual source/key metadata into transient JSON.
 - Failure modes: Empty normalized input, no enabled exact match, unreadable sources, and JSON/XML
   projection failures return `nil` so the controller presents Android's not-found feedback.
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

        /// Actual globally selected JSword book category.
        let category: ModuleCategory

        /// Actual selected-book features serialized into the fragment payload.
        let features: ModuleFeatures

        /// Resolves the first matching dictionary key variant for this module.
        let lookup: ([String]) -> BibleReaderStrongsDocumentBuilder.DictionaryLookupResult?

        /**
         Creates a lightweight dictionary module projection.

         - Parameters:
           - name: SWORD module initials used for fragment identity.
           - abbreviation: User-facing short module label for tabs.
           - v11n: Concrete SwordBook versification, or nil for dictionary backends.
           - language: Actual source language with Android's English fallback already applied.
           - direction: Actual source reading direction.
           - category: Actual selected-book category.
           - features: Actual selected-book features.
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
            category: ModuleCategory = .dictionary,
            features: ModuleFeatures = [],
            lookup: @escaping ([String]) -> BibleReaderStrongsDocumentBuilder.DictionaryLookupResult?
        ) {
            self.name = name
            self.abbreviation = abbreviation
            self.v11n = v11n
            self.language = language
            self.direction = direction
            self.category = category
            self.features = features
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
        disabledDictionaryNames: @escaping () -> SwordJavaExactStringSet
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
        disabledDictionaryNames: @escaping () -> SwordJavaExactStringSet
    ) {
        self.modules = {
            let disabled = disabledDictionaryNames()
            return installedDictionarySources().compactMap { source in
                let info = source.info
                guard Self.isEligibleWordLookupDictionary(
                    info,
                    disabledDictionaryNames: disabled
                ) else {
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

     Android trims whitespace and strips trailing punctuation before one JSword `Book.getKey` call.
     iOS applies the same text transform and sends that single value to each backend; RawLD and
     GenBook adapters own their respective JSword normalization instead of host-generated aliases.

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
        var fragments: [BibleReaderMultiFragmentDocumentBuilder.Fragment] = []

        for module in enabledModules {
            guard let lookup = module.lookup(keyOptions) else { continue }
            let xml = lookup.payloadReadyXML ?? (lookup.isNativeHtml
                ? BibleReaderStrongsDocumentBuilder.buildDictionaryEntryHTML(
                    renderedText: lookup.renderedText
                )
                : BibleReaderStrongsDocumentBuilder.buildDictionaryEntryXML(
                    rawEntry: lookup.rawEntry,
                    renderedText: lookup.renderedText
                ))
            let fragmentFeatures = AndroidDictionaryFragmentMetadata.features(
                from: module.features,
                keyName: lookup.actualKey
            )
            fragments.append((
                xml: xml,
                key: AndroidDictionaryFragmentMetadata.fragmentKey(
                    bookInitials: module.name,
                    keyOsisID: lookup.osisID
                ),
                keyName: lookup.actualKey,
                osisRef: lookup.osisRef,
                bookCategory: AndroidDictionaryFragmentMetadata.bookCategoryName(
                    for: module.category
                ),
                bookInitials: module.name,
                bookAbbreviation: module.abbreviation,
                v11n: module.v11n,
                language: module.language,
                direction: module.direction,
                features: fragmentFeatures,
                hasStrongs: module.features.contains(.strongsNumbers),
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
        disabledDictionaryNames: SwordJavaExactStringSet
    ) -> [DictionaryModule] {
        var result: [DictionaryModule] = []
        for info in swordManager.installedModules() where Self.isEligibleWordLookupDictionary(
            info,
            disabledDictionaryNames: disabledDictionaryNames
        ) {
            guard let module = swordManager.module(named: info.name) else { continue }
            let source = BibleReaderInstalledDictionarySource.sword(module)
            result.append(
                DictionaryModule(
                    name: module.info.name,
                    abbreviation: source.abbreviation,
                    v11n: source.versificationName,
                    language: module.info.language.isEmpty ? "en" : module.info.language,
                    direction: module.info.isRightToLeft ? "rtl" : "ltr",
                    category: module.info.category,
                    features: module.info.features,
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

    /**
     Applies Android's selected-word dictionary category, feature, and inverse-selection policy.

     - Parameters:
       - info: Installed book metadata to classify.
       - disabledDictionaryNames: Exact Java module initials disabled by the user.
     - Returns: `true` only for an enabled plain dictionary book.
     - Side effects: None.
     - Failure modes: Wrong-category, Strong's, morphology, and exactly disabled books return false;
       Java-distinct NFC/NFD or case siblings do not disable each other.
     */
    static func isEligibleWordLookupDictionary(
        _ info: ModuleInfo,
        disabledDictionaryNames: SwordJavaExactStringSet
    ) -> Bool {
        info.category == .dictionary
            && !info.features.contains(.greekDef)
            && !info.features.contains(.hebrewDef)
            && !info.features.contains(.greekParse)
            && !disabledDictionaryNames.contains(info.name)
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
            category: source.info.category,
            features: source.info.features,
            lookup: { source.lookup(keyOptions: $0) }
        )
    }

    /**
     Produces the one key Android passes to the selected dictionary's own `getKey` implementation.

     RawLD case folding, `CaseSensitiveKeys`, Strong padding, and GenBook tiers belong to the backend
     resolver. Adding host-generated lowercase/title-case aliases here could turn an Android miss
     into content or select a distinct logical record.

     - Parameter query: Normalized selected-word lookup key.
     - Returns: The normalized selected-word query as one backend candidate.
     - Side effects: None.
     - Failure modes: Empty query returns empty variants.
     */
    private func wordLookupKeyOptions(for query: String) -> [String] {
        query.isEmpty ? [] : [query]
    }

}
