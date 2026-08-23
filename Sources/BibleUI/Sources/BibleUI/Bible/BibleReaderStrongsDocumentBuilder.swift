import Foundation
import BibleCore
import BibleView
import SwordKit
import os.log

private let strongsDocumentBuilderLogger = Logger(subsystem: "org.andbible", category: "BibleReaderStrongsDocumentBuilder")

/**
 Resolves builder copy from the application bundle while declaring Android-owned keys literally.

 - Parameters:
   - key: Localization resource key requested by the document builder.
   - defaultValue: English fallback used for non-Android-owned future keys.
 - Returns: The localized bundle value or its caller-provided fallback.
 - Side effects: Reads `Bundle.main` localization resources.
 - Failure modes: Missing `document_not_installed` resources use Android's exact English sentence;
   other missing keys use `defaultValue`.
 */
func bibleReaderAndroidDocumentLocalizedString(
    _ key: String,
    _ defaultValue: String
) -> String {
    if key == "document_not_installed" {
        return Bundle.main.localizedString(
            forKey: "document_not_installed",
            value: "Please download '%s'",
            table: nil
        )
    }
    return Bundle.main.localizedString(forKey: key, value: defaultValue, table: nil)
}

/**
 Builds Android-style Strong's, morphology, and dictionary `MultiDocument` payloads.

 `BibleReaderController` owns reader orchestration and bridge routing; this builder owns the
 dictionary-document rules needed to produce the Vue payload. The rules here intentionally mirror the
 Android/JSword behavior iOS depends on for Strong's lookup key families, selected dictionary
 preferences, morphology module selection, and missing-dictionary fallback documents.

 - Side effects: Reads installed-book metadata/preferences, performs exact backend lookups, updates
   the injected per-module preferred-family cache after accepted Strong's hits, and serializes JSON.
 - Failure modes: Returns no payload for installed-book misses, unresolved explicit selections, or
   encoding/read failures; only automatic true-absence paths synthesize localized download content.
 */
struct BibleReaderStrongsDocumentBuilder {
    /// Reads a persisted string-set preference such as selected Strong's dictionary modules.
    typealias SelectedPreferenceValues = (AppPreferenceKey) -> [String]

    /// Resolves a localized string by key with a caller-provided default value.
    typealias LocalizedString = (_ key: String, _ defaultValue: String) -> String

    /// Resolves one explicit persisted book token through Android's global installed-book identity.
    typealias InstalledDictionarySourceNamed = (String) -> BibleReaderInstalledDictionarySource?

    /// Active SWORD manager used to resolve installed dictionary and morphology modules.
    private let swordManager: SwordManager?

    /// Android-style global dictionary inventory used by production SWORD/SQLite lookup.
    private let installedDictionarySources: (() -> [BibleReaderInstalledDictionarySource])?

    /// Inclusive global registry metadata used to distinguish locked installation from absence.
    private let installedBookMetadata: (() -> [ModuleInfo])?

    /// Global JSword-identity resolver used only for nonempty explicit dictionary preferences.
    private let installedDictionarySourceNamed: InstalledDictionarySourceNamed?

    /// Preference reader for Android-parity Strong's and morphology module selections.
    private let selectedPreferenceValues: SelectedPreferenceValues

    /// User-visible module label projection used by Vue tabs.
    private let moduleDisplayLabel: (SwordModule) -> String

    /// Localized string lookup used for synthetic fallback documents.
    private let localizedString: LocalizedString

    /// Per-book Android key-family history shared across production builder lifetimes.
    private let strongsLookupKeyPreferenceCache: AndroidStrongsKeyPreferenceCache

    /**
     Common lookup facade for SWORD and restored MyBible Strong's dictionary modules.

     Android exposes both module families through JSword `Book` discovery after MyBible import. iOS
     keeps the render path shared by projecting each supported source into the same exact-key lookup
     contract instead of branching the Vue document shape by backing store.
     */
    private struct LexiconModule {
        /// Durable module initials used in Vue fragment identity and restored `BookAndKeyList` keys.
        let name: String

        /// User-facing tab label shown by the Vue `MultiDocument` tab rail.
        let abbreviation: String

        /// SWORD versification for real SWORD books; custom Android drivers use `nil`.
        let v11n: String?

        /// Source language exposed to Vue.
        let language: String

        /// Source reading direction exposed to Vue.
        let direction: String

        /// Actual globally resolved book category serialized into Android's fragment payload.
        let category: ModuleCategory

        /// Actual installed-book features used for fragment metadata and aggregate content type.
        let features: ModuleFeatures

        /// Exact-key dictionary lookup closure for the backing module type.
        let lookup: ([String]) -> DictionaryLookupResult?
    }

    /**
     Records whether dictionary candidates came from an explicit user selection or automatic
     installed-module discovery.

     A nonempty preference is authoritative even when none of its named modules can be resolved.
     Keeping that state distinct from automatic discovery prevents a stale or unavailable explicit
     selection from silently opening a different dictionary or an automatic download fallback.
     */
    private enum LexiconModuleResolution {
        /// Modules resolved from a nonempty explicit preference; the array may be empty.
        case explicit([LexiconModule])

        /// Modules resolved through automatic installed-module discovery; the array may be empty.
        case automatic([LexiconModule], hasInstalledCompatibleBook: Bool)

        /**
         Returns the resolved candidates without discarding their selection provenance.

         - Returns: Explicitly selected or automatically discovered dictionary candidates.
         - Side effects: None.
         - Failure modes: Returns an empty array when no candidate resolved.
         */
        var modules: [LexiconModule] {
            switch self {
            case .explicit(let modules), .automatic(let modules, _):
                return modules
            }
        }

        /**
         Reports whether Android's synthetic missing-module document is appropriate.

         - Returns: `true` only when automatic discovery found no compatible module.
         - Side effects: None.
         - Failure modes: Explicit selections always return `false`, including unresolved ones.
         */
        var shouldEmitMissingModuleFallback: Bool {
            switch self {
            case .explicit:
                return false
            case .automatic(let modules, let hasInstalledCompatibleBook):
                return modules.isEmpty && !hasInstalledCompatibleBook
            }
        }
    }

    /**
     Creates a Strong's document builder with explicit dependencies.

     - Parameters:
       - swordManager: Active SWORD manager for installed module discovery.
       - selectedPreferenceValues: Preference lookup for selected dictionary/morphology modules.
       - moduleDisplayLabel: Display-label projection for SWORD modules.
       - localizedString: Localization lookup with default-value fallback.
       - strongsLookupKeyPreferenceCache: Isolated per-book preferred-family state for this builder.
     - Side effects: None during construction.
     - Failure modes: Missing SWORD or preferences are handled by payload-building methods.
     */
    init(
        swordManager: SwordManager?,
        selectedPreferenceValues: @escaping SelectedPreferenceValues,
        moduleDisplayLabel: @escaping (SwordModule) -> String = Self.moduleDisplayLabel,
        localizedString: @escaping LocalizedString = bibleReaderAndroidDocumentLocalizedString,
        strongsLookupKeyPreferenceCache: AndroidStrongsKeyPreferenceCache = .init()
    ) {
        self.swordManager = swordManager
        self.installedDictionarySources = nil
        self.installedBookMetadata = nil
        self.installedDictionarySourceNamed = nil
        self.selectedPreferenceValues = selectedPreferenceValues
        self.moduleDisplayLabel = moduleDisplayLabel
        self.localizedString = localizedString
        self.strongsLookupKeyPreferenceCache = strongsLookupKeyPreferenceCache
    }

    /**
     Creates a Strong's builder from Android's global installed-book registry.

     - Parameters:
       - installedDictionarySources: Deferred globally resolved SWORD and SQLite dictionary sources.
       - installedBookMetadata: Deferred inclusive admitted-book metadata, including locked books.
       - installedDictionarySourceNamed: Global resolver for explicit initials or full-name tokens.
       - selectedPreferenceValues: Preference lookup for selected dictionary/morphology modules.
       - localizedString: Localization lookup with default-value fallback.
       - strongsLookupKeyPreferenceCache: Shared per-book preferred-family state.
     - Side effects: None during construction; installed books and settings are read for each build.
     - Failure modes: Missing, shadowed, locked, and unsupported SQLite sources are omitted.
     */
    init(
        installedDictionarySources: @escaping () -> [BibleReaderInstalledDictionarySource],
        installedBookMetadata: @escaping () -> [ModuleInfo],
        installedDictionarySourceNamed: @escaping InstalledDictionarySourceNamed,
        selectedPreferenceValues: @escaping SelectedPreferenceValues,
        localizedString: @escaping LocalizedString = bibleReaderAndroidDocumentLocalizedString,
        strongsLookupKeyPreferenceCache: AndroidStrongsKeyPreferenceCache = .shared
    ) {
        self.swordManager = nil
        self.installedDictionarySources = installedDictionarySources
        self.installedBookMetadata = installedBookMetadata
        self.installedDictionarySourceNamed = installedDictionarySourceNamed
        self.selectedPreferenceValues = selectedPreferenceValues
        self.moduleDisplayLabel = Self.moduleDisplayLabel
        self.localizedString = localizedString
        self.strongsLookupKeyPreferenceCache = strongsLookupKeyPreferenceCache
    }

    /**
     Builds a Vue `MultiDocument` payload from Strong's numbers and Robinson morphology codes.

     Android opens these results as a special `Multi` general-book document. Real Strong's or
     morphology definitions set `contentType: "strongs"`; fake missing-module fragments and empty
     Robinson results retain a null content type. iOS preserves that distinction so dictionary tabs,
     recursive Strong's links, per-request fallbacks, and links-window identity stay aligned. A
     compatible installed dictionary contributes only successful entries; a missing key never
     masquerades as a missing installation. Explicit module selections remain authoritative even
     when their selected module is unavailable.

     - Parameters:
       - strongs: Strong's numbers parsed from `ab-w://` query items.
       - robinson: Morphology codes parsed from `ab-w://` query items.
       - stateJSON: Optional opaque Vue state to restore into the result document.
     - Returns: Serialized Vue `MultiDocument` JSON, including Android's empty `Multi` for a handled
       Robinson miss, or `nil` for a Strong-only installed-entry miss.
     - Side effects: Reads installed SWORD modules and temporarily moves dictionary cursors.
     - Failure modes: Automatic discovery with no compatible Strong's or morphology dictionary
       produces the Android-style download fallback. Unresolved explicit selections and installed
       Strong dictionaries with no matching entry are omitted. Robinson misses retain Android's
       empty `Multi` navigation contract.
     */
    func buildStrongsMultiDocumentJSON(strongs: [String], robinson: [String], stateJSON: String? = nil) -> String? {
        strongsDocumentBuilderLogger.info(
            "buildStrongsMultiDocumentJSON: strongs=\(strongs), robinson=\(robinson), swordManager=\(self.swordManager == nil ? "nil" : "alive")"
        )
        var fragments: [BibleReaderMultiFragmentDocumentBuilder.Fragment] = []
        var containsStrongsOrMorphologyContent = false

        for num in strongs {
            let lexiconResolution = findAllLexiconModules(for: num)
            let lexModules = lexiconResolution.modules
            strongsDocumentBuilderLogger.info("buildStrongsMultiDocumentJSON: num=\(num), lexModules=\(lexModules.map { $0.name })")
            guard !lexModules.isEmpty else {
                if lexiconResolution.shouldEmitMissingModuleFallback {
                    fragments.append(missingStrongsDictionaryFragment(for: num))
                }
                continue
            }

            let keyCandidates = Self.strongsLookupKeyCandidates(for: num)
            strongsDocumentBuilderLogger.info(
                "buildStrongsMultiDocumentJSON: keyOptions=\(keyCandidates.map(\.value))"
            )
            for mod in lexModules {
                if let lookup = lookupStrongs(in: mod, candidates: keyCandidates) {
                    let isHebrew = Self.isHebrewStrongsNumber(num)
                    let keyName = lookup.actualKey
                    let strongsLinkPrefix = isHebrew ? "H" : "G"
                    let xml = dictionaryEntryXML(
                        for: lookup,
                        moduleInitials: mod.name,
                        strongsLinkPrefix: strongsLinkPrefix
                    )
                    let features = AndroidDictionaryFragmentMetadata.features(
                        from: mod.features,
                        keyName: keyName
                    )
                    containsStrongsOrMorphologyContent =
                        containsStrongsOrMorphologyContent
                        || AndroidDictionaryFragmentMetadata.usesStrongsContentType(mod.features)

                    fragments.append((
                        xml: xml,
                        key: AndroidDictionaryFragmentMetadata.fragmentKey(
                            bookInitials: mod.name,
                            keyOsisID: lookup.osisID
                        ),
                        keyName: keyName,
                        osisRef: lookup.osisRef,
                        bookCategory: AndroidDictionaryFragmentMetadata.bookCategoryName(
                            for: mod.category
                        ),
                        bookInitials: mod.name,
                        bookAbbreviation: mod.abbreviation,
                        v11n: mod.v11n,
                        language: mod.language,
                        direction: mod.direction,
                        features: features,
                        hasStrongs: mod.features.contains(.strongsNumbers),
                        isNativeHtml: lookup.isNativeHtml
                    ))
                }
            }
        }

        if !robinson.isEmpty {
            let morphologyResolution = findMorphologyModules()
            let morphModules = morphologyResolution.modules
            for code in robinson {
                guard !morphModules.isEmpty else {
                    if morphologyResolution.shouldEmitMissingModuleFallback {
                        fragments.append(missingMorphologyDictionaryFragment(for: code))
                    }
                    continue
                }
                for mod in morphModules {
                    if let lookup = mod.lookup([code]) {
                        let keyName = lookup.actualKey
                        let xml = dictionaryEntryXML(
                            for: lookup,
                            moduleInitials: mod.name
                        )
                        let features = AndroidDictionaryFragmentMetadata.features(
                            from: mod.features,
                            keyName: keyName
                        )
                        containsStrongsOrMorphologyContent =
                            containsStrongsOrMorphologyContent
                            || AndroidDictionaryFragmentMetadata.usesStrongsContentType(mod.features)
                        fragments.append((
                            xml: xml,
                            key: AndroidDictionaryFragmentMetadata.fragmentKey(
                                bookInitials: mod.name,
                                keyOsisID: lookup.osisID
                            ),
                            keyName: keyName,
                            osisRef: lookup.osisRef,
                            bookCategory: AndroidDictionaryFragmentMetadata.bookCategoryName(
                                for: mod.category
                            ),
                            bookInitials: mod.name,
                            bookAbbreviation: mod.abbreviation,
                            v11n: mod.v11n,
                            language: mod.language,
                            direction: mod.direction,
                            features: features,
                            hasStrongs: mod.features.contains(.strongsNumbers),
                            isNativeHtml: lookup.isNativeHtml
                        ))
                    }
                }
            }
        }

        if fragments.isEmpty {
            strongsDocumentBuilderLogger.info("buildStrongsMultiDocumentJSON: no definitions found")
            guard !robinson.isEmpty else { return nil }
        }

        return BibleReaderMultiFragmentDocumentBuilder.buildJSON(
            fragments: fragments,
            contentType: containsStrongsOrMorphologyContent ? "strongs" : nil,
            stateJSON: stateJSON
        )
    }

    /**
     Projects one exact dictionary lookup into Android's final fragment XML contract.

     - Parameters:
       - lookup: Exact backend-owned key plus either processed payload or typed read failure.
       - moduleInitials: Actual selected book initials used by localized error text.
       - strongsLinkPrefix: Optional compatibility prefix for legacy unprocessed entry bodies.
     - Returns: Payload-ready OSIS, localized unanchored error OSIS, native HTML compatibility body,
       or the legacy structured dictionary wrapper in that precedence order.
     - Side effects: Reads the injected localization source only for a typed commentary read error.
     - Failure modes: Missing localized resources use Android's exact English message; malformed
       unprocessed legacy markup retains the existing deterministic wrapper behavior.
     */
    private func dictionaryEntryXML(
        for lookup: DictionaryLookupResult,
        moduleInitials: String,
        strongsLinkPrefix: String? = nil
    ) -> String {
        if lookup.payloadFailure == .keyNotInDocument {
            return Self.keyNotInDocumentXML(
                keyName: lookup.actualKey,
                moduleInitials: moduleInitials,
                localizedString: localizedString
            )
        }
        if let payloadReadyXML = lookup.payloadReadyXML {
            return payloadReadyXML
        }
        if lookup.isNativeHtml {
            return Self.buildDictionaryEntryHTML(
                renderedText: lookup.renderedText,
                strongsLinkPrefix: strongsLinkPrefix
            )
        }
        return Self.buildDictionaryEntryXML(
            rawEntry: lookup.rawEntry,
            renderedText: lookup.renderedText,
            strongsLinkPrefix: strongsLinkPrefix
        )
    }

    /**
     Builds Android's localized `DocumentNotFound` payload for an already-resolved book/key.

     - Parameters:
       - keyName: Exact resolved `Key.name` used as Android format argument one.
       - moduleInitials: Exact selected `Book.initials` used as format argument two.
     - Returns: One plain `<div>` containing XML-safe localized text and no BVA anchors.
     - Side effects: Reads the injected localization source.
     - Failure modes: Missing resources use Android's English default; unsupported placeholder
       syntax remains literal instead of being evaluated as an unsafe format string.
     */
    static func keyNotInDocumentXML(
        keyName: String,
        moduleInitials: String,
        localizedString: LocalizedString
    ) -> String {
        let format = localizedString(
            "error_key_not_in_document2",
            "%1$s was not found in document %2$s."
        )
        let keySentinel = "ANDBIBLE_MISSING_KEY_SENTINEL"
        let moduleSentinel = "ANDBIBLE_MISSING_KEY_MODULE_SENTINEL"
        let localizedMessage = format
            .replacingOccurrences(of: "%1$s", with: keySentinel)
            .replacingOccurrences(of: "%1$@", with: keySentinel)
            .replacingOccurrences(of: "%2$s", with: moduleSentinel)
            .replacingOccurrences(of: "%2$@", with: moduleSentinel)
        let escapedMessage = Self.escapeXML(localizedMessage)
            .replacingOccurrences(of: keySentinel, with: Self.escapeXML(keyName))
            .replacingOccurrences(of: moduleSentinel, with: Self.escapeXML(moduleInitials))
        return "<div>\(escapedMessage)</div>"
    }

    /**
     Resolves one Strong's entry using Android's per-book preferred key-family history.

     - Parameters:
       - module: Installed dictionary facade whose canonical initials key the preference cache.
       - candidates: Four typed candidates in Android default order.
     - Returns: First exact accepted lookup, or `nil` when every family misses.
     - Side effects: Reads the module, may move and restore a SWORD cursor, and records only the
       family that produced accepted exact content.
     - Failure modes: Backend failures and nearest-entry mismatches fail the affected family closed;
       no preference is recorded for rejected or missing content.
     - Important: Cache ordering and update are lock-protected, while backend lookup retains each
       source's existing serialization contract.
     */
    private func lookupStrongs(
        in module: LexiconModule,
        candidates: [AndroidStrongsKeyCandidate]
    ) -> DictionaryLookupResult? {
        let orderedCandidates = strongsLookupKeyPreferenceCache.orderedCandidates(
            candidates,
            moduleInitials: module.name
        )
        for candidate in orderedCandidates {
            guard let result = module.lookup([candidate.value]) else { continue }
            strongsLookupKeyPreferenceCache.record(
                candidate.family,
                moduleInitials: module.name
            )
            return result
        }
        return nil
    }

    /**
     Builds the Android-style missing-document fallback for unavailable Strong's dictionaries.

     - Parameter strongsNumber: Strong's number whose dictionary module could not be resolved.
     - Returns: Android's fake-book fragment with the raw requested key and embedded module link.
     - Side effects: Reads localized strings through the injected localization closure.
     - Failure modes: Empty or malformed numbers still produce a deterministic fallback key.
     */
    private func missingStrongsDictionaryFragment(
        for strongsNumber: String
    ) -> BibleReaderMultiFragmentDocumentBuilder.Fragment {
        let isHebrew = Self.isHebrewStrongsNumber(strongsNumber)
        let moduleName = isHebrew ? "StrongsHebrew" : "StrongsGreek"
        let message = missingDocumentMessage(moduleName: moduleName)
        let xml = """
        <div>\(message)</div>
        """
        return (
            xml: xml,
            key: AndroidDictionaryFragmentMetadata.fragmentKey(
                bookInitials: moduleName,
                keyOsisID: strongsNumber
            ),
            keyName: strongsNumber,
            osisRef: strongsNumber,
            bookCategory: DocumentCategory.dictionary.rawValue,
            bookInitials: moduleName,
            bookAbbreviation: moduleName,
            v11n: nil,
            language: "en",
            direction: "ltr",
            features: OsisFeatures(),
            hasStrongs: false,
            isNativeHtml: false
        )
    }

    /**
     Builds Android's missing-document fallback for an automatically unresolved Robinson module.

     - Parameter morphologyCode: Robinson morphology code whose backing module is unavailable.
     - Returns: A synthetic morphology fragment linking directly to the Robinson download.
     - Side effects: Reads localized strings through the injected localization closure.
     - Failure modes: Empty or malformed codes still produce a deterministic fallback key.
     */
    private func missingMorphologyDictionaryFragment(
        for morphologyCode: String
    ) -> BibleReaderMultiFragmentDocumentBuilder.Fragment {
        let moduleName = "Robinson"
        let message = missingDocumentMessage(moduleName: moduleName)
        let xml = """
        <div>\(message)</div>
        """
        return (
            xml: xml,
            key: AndroidDictionaryFragmentMetadata.fragmentKey(
                bookInitials: moduleName,
                keyOsisID: morphologyCode
            ),
            keyName: morphologyCode,
            osisRef: morphologyCode,
            bookCategory: DocumentCategory.dictionary.rawValue,
            bookInitials: moduleName,
            bookAbbreviation: moduleName,
            v11n: nil,
            language: "en",
            direction: "ltr",
            features: OsisFeatures(),
            hasStrongs: false,
            isNativeHtml: false
        )
    }

    /**
     Formats Android's localized missing-document sentence around a module-specific download link.

     Android resources use `%s`, while imported Apple resources may use `%@` or positional `%1$s`.
     A sentinel is substituted before XML escaping so localized punctuation remains text and only
     the module-name argument becomes Android's `AndBibleLink` markup.

     - Parameter moduleName: Canonical fake-book initials used as both link text and Downloads seed.
     - Returns: XML-safe localized sentence containing one clickable module-name link.
     - Side effects: Reads the injected localization source.
     - Failure modes: Missing translations use Android's English default. Unknown placeholder forms
       remain visible rather than interpreting an unsafe format string.
     */
    private func missingDocumentMessage(moduleName: String) -> String {
        let format = localizedString(
            "document_not_installed",
            "Please download '%s'"
        )
        let sentinel = "ANDBIBLE_MISSING_MODULE_LINK_SENTINEL"
        let localizedMessage = format
            .replacingOccurrences(of: "%1$s", with: sentinel)
            .replacingOccurrences(of: "%s", with: sentinel)
            .replacingOccurrences(of: "%@", with: sentinel)
        let escapedMessage = Self.escapeXML(localizedMessage)
        let escapedModuleName = Self.escapeXML(moduleName)
        let link = "<AndBibleLink href=\"download://?initials=\(escapedModuleName)\">\(escapedModuleName)</AndBibleLink>"
        return escapedMessage.replacingOccurrences(of: sentinel, with: link)
    }

    /**
     Returns Strong's key strings in Android's typed family order.

     - Parameter strongsNumber: Decoded external Strong's key, including any trailing decoration.
     - Returns: Raw, five-digit, five-digit-plus-carriage-return, and category values. Duplicate
       strings remain present because Android caches and reorders the typed family, not the value.
     - Side effects: None.
     - Failure modes: Invalid grammar retains Android's literal null-base family outputs rather than
       inventing valid numeric aliases.
    */
    static func strongsLookupKeyOptions(for strongsNumber: String) -> [String] {
        strongsLookupKeyCandidates(for: strongsNumber).map(\.value)
    }

    /**
     Builds Android's four typed Strong's lookup families.

     Android's `LinkControl.getStrongsKey` parses an optional uppercase `G`/`H`, greedily consumes
     leading zeroes, accepts decorations after the digits, and tries raw, five-digit, five-digit plus
     carriage return, then category-plus-unpadded keys. No libsword-only aliases are added because
     doing so could turn an Android miss into iOS content or select a distinct logical record.

     - Parameter strongsNumber: Decoded external Strong's key before normalization.
     - Returns: Ordered typed candidates with duplicate values retained under distinct families.
     - Side effects: None.
     - Failure modes: Values outside Android's anchored grammar retain Android's raw, empty,
       carriage-return, and category-plus-`null` typed family values.
     */
    static func strongsLookupKeyCandidates(
        for strongsNumber: String
    ) -> [AndroidStrongsKeyCandidate] {
        let categoryPrefix = isHebrewStrongsNumber(strongsNumber) ? "H" : "G"
        return AndroidStrongsKeyResolution.candidates(
            for: strongsNumber,
            categoryPrefix: categoryPrefix
        )
    }

    /**
     Mirrors Android's external Strong's URI category rule.

     Android reads the raw first UTF-16 `Char` without trimming or case folding and treats only code
     unit `0x0047` (`G`) as Greek. This differs from Swift grapheme clustering when `G` is followed
     by a combining mark. `H`-prefixed, prefixless numeric, lowercase `g`, leading-space, and legacy
     non-`G` values all route to the Hebrew key family.

     - Parameter strongsNumber: External Strong's value before dictionary-key normalization.
     - Returns: `false` only when the raw first UTF-16 code unit is uppercase `G` (`0x0047`).
     - Side effects: None.
     - Failure modes: Empty or malformed values deterministically classify as Hebrew.
     */
    static func isHebrewStrongsNumber(_ strongsNumber: String) -> Bool {
        strongsNumber.utf16.first != 0x0047
    }

    /**
     Captures one backend-resolved key and its Android document projection.

     Identity fields come from the actual accepted `Key`; body fields either carry a fully processed
     OSIS fragment or the legacy adapter inputs. A typed payload failure remains a successful key
     resolution so callers can emit Android's actual-book error fragment instead of retrying.

     - Side effects: None; values are immutable after construction.
     - Failure modes: Backend misses are represented by the absence of this value, while supported
       post-resolution read failures use `payloadFailure`.
     */
    struct DictionaryLookupResult {
        /**
         Typed Android document outcome retained after a backend has resolved an exact key.

         A commentary-category `SwordDictionary` still owns its resolved key when its assembled
         BookData has no direct verse. Android catches that read failure and emits a localized error
         fragment for the actual book/key instead of treating the definition as an absent entry.
         */
        enum PayloadFailure: Equatable {
            /// Emit Android's localized key-not-in-document OSIS error without BVA anchors.
            case keyNotInDocument
        }

        /// Exact user-visible `Key.name` reported by the selected book.
        let actualKey: String

        /// Exact `Key.osisID` used for Android's sanitized fragment identity.
        let osisID: String

        /// Exact `Key.osisRef` serialized into the fragment payload.
        let osisRef: String

        /// Raw entry XML/text for the matched key.
        let rawEntry: String
        /// SWORD-rendered text for the matched key.
        let renderedText: String
        /// Whether `renderedText` is browser HTML that should bypass OSIS conversion.
        let isNativeHtml: Bool

        /// Complete Android-processed fragment XML that must bypass dictionary wrapping.
        let payloadReadyXML: String?

        /// Typed post-resolution error rendered as an Android `OsisError` fragment.
        let payloadFailure: PayloadFailure?

        /**
         Creates a dictionary lookup result with explicit renderer expectations.

         - Parameters:
           - actualKey: User-visible `Key.name` resolved by the backing module.
           - osisID: Resolved `Key.osisID`; defaults to `actualKey` for flat dictionary keys.
           - osisRef: Resolved `Key.osisRef`; defaults to `actualKey` for flat dictionary keys.
           - rawEntry: Raw entry payload preserved for non-SwordDictionary compatibility paths.
           - renderedText: Display-ready body preserved for non-SwordDictionary compatibility paths.
           - isNativeHtml: Whether the compatibility result is browser HTML. Android
             `SwordDictionary` sources, including MyBible, leave this `false` and use
             `payloadReadyXML`.
           - payloadReadyXML: Optional fully processed fragment XML used without further wrapping.
           - payloadFailure: Optional typed Android read failure for this already-resolved key.
         - Side effects: None.
         - Failure modes: None.
         */
        init(
            actualKey: String,
            osisID: String? = nil,
            osisRef: String? = nil,
            rawEntry: String,
            renderedText: String,
            isNativeHtml: Bool = false,
            payloadReadyXML: String? = nil,
            payloadFailure: PayloadFailure? = nil
        ) {
            self.actualKey = actualKey
            self.osisID = osisID ?? actualKey
            self.osisRef = osisRef ?? actualKey
            self.rawEntry = rawEntry
            self.renderedText = renderedText
            self.isNativeHtml = isNativeHtml
            self.payloadReadyXML = payloadReadyXML
            self.payloadFailure = payloadFailure
        }
    }

    /**
     Tries each Android key candidate through the selected SWORD book's JSword key contract.

     RawLD backends normalize case and optional Strong's padding before exact index comparison.
     JSword derives padding from the first binary-search midpoint, so iOS resolves the selected
     source-index key before asking libsword to read that exact stored record.
     Body/headword text is deliberately not used as a second ownership test: Android accepts the
     key returned by `Book.getKey` and renders `BookData` even when entry markup names another key.

     - Parameters:
       - module: Readable SWORD module queried through serialized cursor access.
       - keyOptions: Ordered keys; Strong's callers pass one typed family per invocation and
         Robinson callers pass exactly the raw code.
     - Returns: First JSword-owned record, preserving its exact stored key, raw body, and rendering.
     - Side effects: Enumerates and caches RawLD keys, then moves the module cursor to accepted keys.
     - Failure modes: Empty/unresolved keys, unrelated nearest-key results, backend enumeration
       failures, and unsupported non-RawLD normalization fail the affected candidate closed.
     */
    static func lookupInModule(_ module: SwordModule, keyOptions: [String]) -> DictionaryLookupResult? {
        strongsDocumentBuilderLogger.info("lookupInModule: \(module.info.name), keyOptions=\(keyOptions)")

        let driver = module.info.moduleDriver
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if driver == "rawgenbook" {
            return lookupInGenBook(module, keyOptions: keyOptions)
        }
        let usesRawLDKeyContract = ["rawld", "rawld4", "zld"].contains(driver)
        let rawLDConfiguration = AndroidJSwordRawLDKeyResolution.Configuration(
            moduleInitials: module.info.name,
            category: module.info.category,
            features: module.info.features,
            caseSensitiveKeys: AndroidJSwordRawLDKeyResolution.javaBoolean(
                module.configEntry("CaseSensitiveKeys")
            ),
            // SwordBookMetaData.DEFAULTS supplies true when this property is absent.
            strongsPadding: module.configEntry("StrongsPadding").map(
                AndroidJSwordRawLDKeyResolution.javaBoolean
            ) ?? true
        )

        let rawLDStoredSlots: [SwordRawDictionaryIndexSlot]?
        if usesRawLDKeyContract {
            rawLDStoredSlots = try? module.loadRawDictionaryIndexSlots()
        } else {
            rawLDStoredSlots = nil
        }
        for key in keyOptions {
            let selectedStoredKey: String?
            let selectedStoredIndex: Int?
            if usesRawLDKeyContract {
                guard let rawLDStoredSlots else { return nil }
                let resolution = AndroidJSwordRawLDKeyResolution.resolve(
                    requestedKey: key,
                    storedSlots: rawLDStoredSlots,
                    configuration: rawLDConfiguration
                )
                selectedStoredKey = resolution?.storedKey
                selectedStoredIndex = resolution?.index
            } else {
                selectedStoredKey = key
                selectedStoredIndex = nil
            }
            guard let selectedStoredKey else { continue }

            if usesRawLDKeyContract {
                guard let selectedStoredIndex else { continue }
                let fragment: SwordRawOSISFragment
                do {
                    fragment = try module.rawDictionaryOSISFragment(
                        forIndex: selectedStoredIndex,
                        storedKey: selectedStoredKey
                    )
                } catch SwordRawOSISFragmentError.missingCommentaryVerse(
                    let key,
                    let keyName,
                    let osisRef
                ) {
                    return DictionaryLookupResult(
                        actualKey: keyName,
                        osisID: key,
                        osisRef: osisRef,
                        rawEntry: "",
                        renderedText: "",
                        payloadFailure: .keyNotInDocument
                    )
                } catch {
                    continue
                }
                strongsDocumentBuilderLogger.info(
                    "lookupInModule: tried key='\(key)', actualKey='\(fragment.keyName)', accepted=true, xmlLen=\(fragment.xml.count)"
                )
                return DictionaryLookupResult(
                    actualKey: fragment.keyName,
                    osisID: fragment.key,
                    osisRef: fragment.osisRef,
                    rawEntry: fragment.originalXML,
                    renderedText: fragment.originalXML,
                    payloadReadyXML: fragment.xml
                )
            }

            let inspection = module.setKeyAndInspect(selectedStoredKey)
            let accepted = inspection.actualKey.utf16.elementsEqual(key.utf16)

            strongsDocumentBuilderLogger.info(
                "lookupInModule: tried key='\(key)', actualKey='\(inspection.actualKey)', accepted=\(accepted), renderLen=\(inspection.renderedText.count)"
            )
            guard accepted else { continue }
            return DictionaryLookupResult(
                actualKey: selectedStoredKey,
                rawEntry: inspection.rawEntry,
                renderedText: inspection.renderedText
            )
        }
        return nil
    }

    /**
     Resolves one candidate through pinned `SwordGenBook.getKey` and reads the selected TreeKey.

     - Parameters:
       - module: Readable RawGenBook whose global TreeKey list backs JSword's local key map.
       - keyOptions: Ordered Strong's typed families or the one raw Robinson code.
     - Returns: First resolved entry with leaf `Key.name` and distinct full-path OSIS identity.
     - Side effects: Enumerates/caches the module key list and performs one cursor-restoring raw OSIS
       read for the selected exact full path.
     - Failure modes: Key-list errors, unmatched candidates, and malformed/unreadable selected OSIS
       fail closed without substituting a nearest tree node.
     */
    private static func lookupInGenBook(
        _ module: SwordModule,
        keyOptions: [String]
    ) -> DictionaryLookupResult? {
        guard let sourceKeys = try? module.loadAllKeys() else { return nil }
        for key in keyOptions {
            guard let resolution = AndroidJSwordGenBookKeyResolution.resolve(
                candidate: key,
                sourceKeys: sourceKeys
            ) else {
                continue
            }
            let fragment: SwordRawOSISFragment
            do {
                fragment = try module.rawGenBookOSISFragment(
                    forKey: resolution.sourceKey,
                    treeKeyCardinality: resolution.subtreeCardinality
                )
            } catch SwordRawOSISFragmentError.missingCommentaryVerse(
                let sourceKey,
                let keyName,
                let osisRef
            ) {
                return DictionaryLookupResult(
                    actualKey: keyName,
                    osisID: resolution.osisRef.isEmpty ? sourceKey : resolution.osisRef,
                    osisRef: resolution.osisRef.isEmpty ? osisRef : resolution.osisRef,
                    rawEntry: "",
                    renderedText: "",
                    payloadFailure: .keyNotInDocument
                )
            } catch {
                continue
            }
            return DictionaryLookupResult(
                actualKey: fragment.keyName,
                osisID: resolution.osisRef,
                osisRef: resolution.osisRef,
                rawEntry: fragment.originalXML,
                renderedText: fragment.originalXML,
                payloadReadyXML: fragment.xml
            )
        }
        return nil
    }

    /**
     Tries Android's Strong's key variants against a restored MyBible dictionary.

     MyBible dictionary topics are exact keys, so unlike SWORD there is no nearest-entry cursor to
     reject. Android exposes the driver as a `SwordDictionary`: an exact row, including an empty
     definition, receives the hidden generated key title before one OSIS/BVA processing pass.

     - Parameters:
       - reader: Validated read-only MyBible dictionary backend.
       - keyOptions: Ordered Android Strong/Robinson candidates; the first exact topic wins.
       - moduleInitials: Actual installed initials used by source-specific OSIS compatibility rules.
     - Returns: Actual topic identity plus payload-ready OSIS, or `nil` when no topic/processable
       entry exists.
     - Side effects: Opens short-lived SQLite reads and runs one OSIS parser/anchor pass per exact row.
     - Failure modes: Missing topics and malformed OSIS continue to the next candidate; all misses
       return `nil`. An exact empty definition remains a successful hidden-title-only fragment.
     */
    static func lookupInMyBibleDictionary(
        _ reader: MyBibleReader,
        keyOptions: [String],
        moduleInitials: String? = nil
    ) -> DictionaryLookupResult? {
        for key in keyOptions {
            guard let entry = reader.getDictionaryEntry(key: key),
                  let processed = try? SwordOSISFragmentProcessor.processDictionarySource(
                    sourceXML: entry,
                    keyName: key,
                    moduleInitials: moduleInitials
                  ) else {
                continue
            }
            return DictionaryLookupResult(
                actualKey: key,
                rawEntry: processed.originalXML,
                renderedText: processed.originalXML,
                payloadReadyXML: processed.xml
            )
        }
        return nil
    }

    /**
     Parsed SWORD-style module config with lowercased keys and duplicate values preserved.
     */
    private struct ParsedSwordConfig {
        /// Bracketed module name from the config header, for example `BDBT`.
        let name: String

        /// Config entries keyed case-insensitively, preserving repeated keys such as `Feature`.
        let values: [String: [String]]
    }

    /**
     Parses the subset of SWORD `.conf` files needed for restored MyBible dictionaries.

     - Parameter url: Config file URL under `mods.d`.
     - Returns: Parsed module name and key/value arrays, or `nil` for unreadable or malformed files.
     - Side effects: Reads one UTF-8 text file.
     - Failure modes: Comments, blank lines, and malformed non-assignment lines are ignored; missing
       module headers return `nil`.
     */
    private static func parseSwordConfig(at url: URL) -> ParsedSwordConfig? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var moduleName: String?
        var values: [String: [String]] = [:]

        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";") else { continue }

            if line.hasPrefix("["), line.hasSuffix("]") {
                let name = String(line.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    moduleName = name
                }
                continue
            }

            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            values[key, default: []].append(value)
        }

        guard let moduleName else { return nil }
        return ParsedSwordConfig(name: moduleName, values: values)
    }

    /**
     Reads the first config value for a lowercased key.
     */
    private static func firstConfigValue(_ key: String, in values: [String: [String]]) -> String? {
        values[key.lowercased()]?.first?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /**
     Resolves a restored MyBible `DataPath` to its SQLite database URL.
     */
    private static func myBibleDatabaseURL(dataPath: String, modulePathURL: URL) -> URL {
        let normalizedPath = dataPath
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let relativePath = normalizedPath.hasPrefix("./")
            ? String(normalizedPath.dropFirst(2))
            : normalizedPath
        let directoryURL = relativePath.hasPrefix("/")
            ? URL(fileURLWithPath: relativePath, isDirectory: true)
            : modulePathURL.appendingPathComponent(relativePath, isDirectory: true)
        return directoryURL.appendingPathComponent("module.SQLite3")
    }

    /**
     Maps SWORD config `Feature` entries into the option set used by Strong's module selection.
     */
    private static func myBibleFeatures(from values: [String]) -> ModuleFeatures {
        values.reduce(into: ModuleFeatures()) { features, value in
            if value.localizedCaseInsensitiveContains("GreekDef") {
                features.insert(.greekDef)
            }
            if value.localizedCaseInsensitiveContains("HebrewDef") {
                features.insert(.hebrewDef)
            }
        }
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
            if let fallbackTitle {
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
        if renderedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "<div>\(titlePrefix)</div>"
        }
        return "<div>\(titlePrefix)<div type=\"paragraph\">\(linkifiedHtml)</div></div>"
    }

    /**
     Builds native HTML for browser-oriented non-SwordDictionary entries.

     Android-compatible MyBible and MySword dictionaries are real `SwordDictionary` instances and
     use the shared OSIS processor instead. This helper remains for sources whose backing contract is
     genuinely browser HTML and only linkifies supported Strong's references.

     - Parameters:
       - renderedText: Exact browser-oriented definition body.
       - strongsLinkPrefix: Optional default prefix for numeric Strong's references.
     - Returns: One native-HTML root preserving the source body.
     - Side effects: None.
     - Failure modes: Malformed source HTML remains source-owned and is sanitized by the bridge.
     */
    static func buildDictionaryEntryHTML(
        renderedText: String,
        strongsLinkPrefix: String? = nil
    ) -> String {
        "<div>\(linkifyRenderedDictionaryHTML(renderedText, defaultPrefix: strongsLinkPrefix))</div>"
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
     Returns the JSword-compatible user-facing abbreviation for a SWORD module.

     - Parameter module: Actual selected native book.
     - Returns: `Abbreviation` after JSword `IniSection`'s Java-trim step, or initials when absent
       or empty. Unicode whitespace above U+0020 remains verbatim.
     - Side effects: Reads one SWORD config entry.
     - Failure modes: Missing and zero-length values fall back deterministically to initials.
     */
    static func moduleDisplayLabel(_ module: SwordModule) -> String {
        BibleReaderJSwordConfigValue.abbreviation(
            module.configEntry("Abbreviation"),
            initials: module.info.name
        )
    }

    /**
     Mirrors Android's curated Strong's dictionary module policy.
     */
    static func isSupportedStrongsDictionaryModuleName(_ name: String) -> Bool {
        StrongsDictionaryPolicy.isSupportedDictionaryModuleName(name)
    }

    /**
     Resolves the dictionary/glossary modules eligible for one Strong's number.

     - Parameter strongsNumber: External Strong's value used to choose Greek or Hebrew preferences.
     - Returns: Explicitly selected candidates when that preference is nonempty, including an empty
       resolution, or automatically discovered compatible candidates when no selection exists.
     - Side effects: Reads current preferences and installed SWORD/restored dictionary metadata.
     - Failure modes: Missing explicit modules remain an authoritative empty explicit resolution;
       absent automatic candidates return an empty automatic resolution that licenses a fallback.
     */
    private func findAllLexiconModules(for strongsNumber: String) -> LexiconModuleResolution {
        let isHebrew = Self.isHebrewStrongsNumber(strongsNumber)
        let feature: ModuleFeatures = isHebrew ? .hebrewDef : .greekDef

        let candidates = lexiconCandidates(feature: feature, manager: swordManager)
        let hasInstalledCompatibleBook = !candidates.isEmpty
            || (installedBookMetadata?().contains { $0.features.contains(feature) } ?? false)
            || (swordManager?.installedModules().contains {
                $0.features.contains(feature)
            } ?? false)
        strongsDocumentBuilderLogger.info("findAllLexiconModules: \(candidates.count) installed lexicon candidates, isHebrew=\(isHebrew)")
        var result: [LexiconModule] = []
        var seen = Set<String>()

        let selectionKey: AppPreferenceKey = isHebrew ? .strongsHebrewDictionary : .strongsGreekDictionary
        let selectedNames = selectedPreferenceValues(selectionKey)
        if !selectedNames.isEmpty {
            for name in selectedNames where seen.insert(name).inserted {
                if let mod = explicitlySelectedLexiconModule(named: name) {
                    result.append(mod)
                }
            }
            return .explicit(result)
        }

        for mod in candidates {
            if seen.insert(mod.name).inserted {
                result.append(mod)
            }
        }

        if !result.isEmpty {
            return .automatic(result, hasInstalledCompatibleBook: true)
        }

        return .automatic(
            result,
            hasInstalledCompatibleBook: hasInstalledCompatibleBook
        )
    }

    /**
     Resolves one explicit persisted book token with JSword's global identity precedence.

     Explicit Android preferences are authoritative and are resolved without category or feature
     filtering: exact initials, exact full name, then Java-style case-insensitive initials or full
     name. Global ownership is preserved, so a locked or unreadable match fails closed instead of
     falling through to a same-named backend.

     - Parameter selectedName: Persisted initials or full module-name token.
     - Returns: Globally owned readable dictionary/glossary facade, or `nil` when unresolved.
     - Side effects: Reads current installed-module metadata and may construct a SWORD facade.
     - Failure modes: Missing, locked, shadowed, and unsupported SQLite owners return `nil`;
       automatic discovery is never substituted for an unresolved explicit token.
     */
    private func explicitlySelectedLexiconModule(named selectedName: String) -> LexiconModule? {
        if let installedDictionarySourceNamed,
           let source = installedDictionarySourceNamed(selectedName) {
            return lexiconModule(source)
        }

        guard let manager = swordManager,
              let info = BibleReaderInstalledModuleLookup.module(
                named: selectedName,
                in: manager.installedModules()
              ),
              let module = manager.readableModule(named: info.name) else {
            return nil
        }
        return swordLexiconModule(module)
    }

    /**
     Builds the installed Strong's dictionary candidates Android would expose for one feature.

     SWORD dictionaries come from libsword's installed module list. Restored MyBible dictionaries are
     stored beside SWORD modules under `mods.d` with `ModDrv=MyBibleDictionary`, which libsword does
     not open directly; this method reads those configs and projects them into the same lookup
     contract when their database is a Strong's dictionary.
     */
    private func lexiconCandidates(
        feature: ModuleFeatures,
        manager: SwordManager?
    ) -> [LexiconModule] {
        if let installedDictionarySources {
            return installedDictionarySources().compactMap { source in
                let info = source.info
                guard info.features.contains(feature) else {
                    return nil
                }
                return lexiconModule(source)
            }
        }

        guard let manager else { return [] }
        let swordModules = manager.installedModules().compactMap { info -> LexiconModule? in
            guard info.features.contains(feature),
                  let mod = manager.readableModule(named: info.name) else {
                return nil
            }
            return swordLexiconModule(mod)
        }

        return swordModules + myBibleLexiconModules(feature: feature, modulePath: manager.modulePath)
    }

    /** Projects one globally resolved SWORD/SQLite dictionary into the shared lookup facade. */
    private func lexiconModule(
        _ source: BibleReaderInstalledDictionarySource
    ) -> LexiconModule {
        LexiconModule(
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
     Wraps a SWORD dictionary module in the common lexicon lookup facade.

     - Parameter module: Installed SWORD dictionary module.
     - Returns: Lookup facade preserving module initials and display label.
     - Side effects: None until the returned closure performs SWORD key lookup.
     */
    private func swordLexiconModule(_ module: SwordModule) -> LexiconModule {
        LexiconModule(
            name: module.info.name,
            abbreviation: moduleDisplayLabel(module),
            v11n: BibleReaderInstalledDictionarySource.sword(module).versificationName,
            language: module.info.language.isEmpty ? "en" : module.info.language,
            direction: module.info.isRightToLeft ? "rtl" : "ltr",
            category: module.info.category,
            features: module.info.features,
            lookup: { keyOptions in
                Self.lookupInModule(module, keyOptions: keyOptions)
            }
        )
    }

    /**
     Finds restored MyBible Strong's dictionaries imported from Android module backups.

     Android converts MyBible dictionaries into JSword books with `Lexicons / Dictionaries` category
     and Greek/Hebrew definition features when `info.is_strong=true`. iOS mirrors that by reading
     the generated `.conf` metadata and opening `module.SQLite3` through `MyBibleReader`.
     */
    private func myBibleLexiconModules(feature: ModuleFeatures, modulePath: String) -> [LexiconModule] {
        let baseURL = URL(fileURLWithPath: modulePath, isDirectory: true)
        let modsDirectory = baseURL.appendingPathComponent("mods.d", isDirectory: true)
        let configs = (try? FileManager.default.contentsOfDirectory(
            at: modsDirectory,
            includingPropertiesForKeys: nil
        )) ?? []

        return configs
            .filter { $0.pathExtension.lowercased() == "conf" }
            .compactMap { myBibleLexiconModule(from: $0, modulePathURL: baseURL, requiredFeature: feature) }
    }

    /**
     Parses one MyBible dictionary module config and opens its backing SQLite database.

     - Parameters:
       - configURL: Module `.conf` file generated under `mods.d` by the Android backup import.
       - modulePathURL: Root SWORD module directory containing `mods.d` and `modules`.
       - requiredFeature: Hebrew or Greek definition feature requested by the Strong's link.
     - Returns: A lexicon facade when the config and SQLite database describe a supported Strong's
       dictionary, otherwise `nil`.
     - Side effects: Reads the config file and opens a read-only SQLite handle captured by the
       returned lookup closure.
     */
    private func myBibleLexiconModule(
        from configURL: URL,
        modulePathURL: URL,
        requiredFeature: ModuleFeatures
    ) -> LexiconModule? {
        guard let config = Self.parseSwordConfig(at: configURL),
              Self.firstConfigValue("moddrv", in: config.values)?.caseInsensitiveCompare("MyBibleDictionary") == .orderedSame,
              let dataPath = Self.firstConfigValue("datapath", in: config.values),
              let reader = MyBibleReader(filePath: Self.myBibleDatabaseURL(
                dataPath: dataPath,
                modulePathURL: modulePathURL
              ).path),
              reader.isDictionary else {
            return nil
        }

        var features = Self.myBibleFeatures(from: config.values["feature"] ?? [])
        if reader.hasStrongsDefinitions {
            features.insert(.hebrewDef)
            features.insert(.greekDef)
        }
        guard features.contains(requiredFeature) else { return nil }

        let abbreviation = Self.firstConfigValue("abbreviation", in: config.values) ?? config.name
        let language = Self.firstConfigValue("lang", in: config.values) ?? "en"
        let rtlLanguages = Set(["ar", "fa", "he", "iw", "ps", "ur", "yi"])
        let direction = rtlLanguages.contains(language.split(separator: "-").first?.lowercased() ?? "")
            ? "rtl"
            : "ltr"
        return LexiconModule(
            name: config.name,
            abbreviation: abbreviation,
            v11n: nil,
            language: language,
            direction: direction,
            category: .dictionary,
            features: features,
            lookup: { keyOptions in
                Self.lookupInMyBibleDictionary(
                    reader,
                    keyOptions: keyOptions,
                    moduleInitials: config.name
                )
            }
        )
    }

    /**
     Resolves morphology dictionaries while preserving Android's explicit-selection authority.

     - Returns: Explicitly selected candidates when the morphology preference is nonempty, including
       an empty resolution, or automatically discovered `GreekParse` candidates otherwise.
     - Side effects: Reads current preferences and installed dictionary metadata.
     - Failure modes: Missing explicit modules remain an authoritative empty explicit resolution;
       absent automatic candidates return an empty automatic resolution that licenses a fallback.
     */
    private func findMorphologyModules() -> LexiconModuleResolution {
        let candidates: [LexiconModule]
        if let installedDictionarySources {
            candidates = installedDictionarySources().compactMap { source in
                let info = source.info
                guard info.features.contains(.greekParse) else {
                    return nil
                }
                return lexiconModule(source)
            }
        } else if let mgr = swordManager {
            candidates = mgr.installedModules().compactMap { info in
                guard info.features.contains(.greekParse),
                      let module = mgr.readableModule(named: info.name) else {
                    return nil
                }
                return swordLexiconModule(module)
            }
        } else {
            candidates = []
        }
        let hasInstalledCompatibleBook = !candidates.isEmpty
            || (installedBookMetadata?().contains {
                $0.features.contains(.greekParse)
            } ?? false)
            || (swordManager?.installedModules().contains {
                $0.features.contains(.greekParse)
            } ?? false)

        var result: [LexiconModule] = []
        var seen = Set<String>()

        let selectedNames = selectedPreferenceValues(.robinsonGreekMorphology)
        if !selectedNames.isEmpty {
            for name in selectedNames where seen.insert(name).inserted {
                if let mod = explicitlySelectedLexiconModule(named: name) {
                    result.append(mod)
                }
            }
            return .explicit(result)
        }

        for mod in candidates {
            if seen.insert(mod.name).inserted {
                result.append(mod)
            }
        }

        if !result.isEmpty {
            return .automatic(result, hasInstalledCompatibleBook: true)
        }

        return .automatic(
            result,
            hasInstalledCompatibleBook: hasInstalledCompatibleBook
        )
    }

    /**
     Transforms dictionary cross-references into clickable Strong's links.
     */
    static func linkifyRenderedDictionaryHTML(_ html: String, defaultPrefix: String? = nil) -> String {
        var result = html

        result = linkifyStructuredDictionaryRefs(in: result, defaultPrefix: defaultPrefix)

        let myBibleStrongLinkPattern = try? NSRegularExpression(
            pattern: #"<a\s+href=(['"])S:([HG]\d{1,5})\1>(.*?)</a>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        if let regex = myBibleStrongLinkPattern {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: "<a href=\"ab-w://?strong=$2\">$3</a>"
            )
        }

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
            pattern: "<br\\s*" + "/?>\\s*(?=<span\\s+class=\"sense\")",
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
                v11n: frag.v11n,
                bookCategory: frag.bookCategory,
                bookInitials: frag.bookInitials,
                bookAbbreviation: frag.bookAbbreviation,
                osisRef: frag.osisRef,
                isNewTestament: false,
                features: frag.features,
                hasStrongs: frag.hasStrongs,
                ordinalRange: nil,
                language: frag.language,
                direction: frag.direction,
                isNativeHtml: frag.isNativeHtml
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
