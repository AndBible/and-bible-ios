import Foundation
import BibleCore
import BibleView
import SwordKit
import os.log

private let restoredMultiDocumentBuilderLogger = Logger(
    subsystem: "org.andbible",
    category: "BibleReaderRestoredMultiDocumentBuilder"
)

/**
 Serialized payload rebuilt from Android's durable `Multi` PageManager key.

 Android restores `FakeBookFactory.multiDocument` by converting the saved `BookAndKeyList` key
 back into source document/key fragments. This value carries the resulting Vue payload plus the
 rendered-content key that native chrome should expose after restoration.

 - Side effects: None; this is an immutable value returned by
   `BibleReaderRestoredMultiDocumentBuilder`.
 - Failure modes: Invalid or unavailable persisted children are filtered before this value is
   created, so callers only receive complete bridge payloads.
 */
struct BibleReaderRestoredMultiDocumentRequest {
    /// Serialized Vue `MultiDocument` payload rebuilt from persisted PageManager state.
    let documentJSON: String

    /// Rendered-content key token, normally `multi` or `strongs`.
    let renderedKey: String

    /// Original Android `BookAndKeyList.osisRef` persistence string.
    let pageKey: String
}

/**
 Rebuilds Android-style restored `Multi` documents from durable PageManager identity.

 Android does not persist rendered links-window HTML directly. It persists a fake
 `general_book/Multi` document whose key is a `BookAndKeyList` string, then reconstructs a
 `MultiFragmentDocument` from the referenced source documents after restore. This builder owns the
 iOS equivalent so `BibleReaderController` no longer needs to know how Bible, dictionary, Strong's,
 and morphology children are rehydrated into Vue fragments.

 - Side effects: Reads exact installed SWORD or SQLite content. SWORD cursor helpers restore prior
   state; SQLite readers use operation-owned read-only connections.
 - Failure modes: Returns `nil` when the persisted key is absent, malformed, references no
   installed source documents, or cannot be encoded. Individual bad children are dropped, matching
   Android's restored-child filtering behavior.
 - Note: The builder is deterministic for a fixed installed-module set and persisted key except for
   the generated `MultiDocument` id, which intentionally mirrors the transient document payloads.
 */
struct BibleReaderRestoredMultiDocumentBuilder {
    /// Resolves source modules named in Android `BookAndKey` children.
    private let moduleResolver: BibleReaderInstalledModuleResolver

    /// Active Bible identity used for Android `null:` current-Bible children.
    private let activeModuleName: String?

    /**
     Creates a restored-document builder for one reader pane.

     - Parameters:
       - swordManager: SWORD manager containing installed source modules.
       - activeModule: Active Bible module used by Android `null:` current-Bible references.
     - Side effects: None during construction.
     - Failure modes: Missing SWORD state is handled by returning `nil` from `build(pageKey:)`.
     */
    init(
        swordManager: SwordManager?,
        activeModule: SwordModule?
    ) {
        self.moduleResolver = BibleReaderInstalledModuleResolver(
            swordManager: swordManager,
            sqliteModules: []
        )
        self.activeModuleName = activeModule?.info.name
    }

    /** Creates a restored-document builder from the pane's shared global module resolver. */
    init(
        moduleResolver: BibleReaderInstalledModuleResolver,
        activeModuleName: String?
    ) {
        self.moduleResolver = moduleResolver
        self.activeModuleName = activeModuleName
    }

    /**
     Reconstructs the Vue `MultiDocument` payload Android derives from a restored `BookAndKeyList`.

     - Parameter pageKey: Persisted Android `BookAndKeyList.osisRef` value from `PageManager`.
     - Returns: A restored payload plus rendered-content key, or `nil` when no child can be
       resolved.
     - Side effects: Reads SWORD module content and may temporarily move module cursors through
       restoring helpers.
     - Failure modes: Drops individual malformed/unavailable children, matching Android's
       `mapNotNull` restore behavior; returns `nil` if all children drop or encoding fails.
     */
    func build(pageKey: String?) -> BibleReaderRestoredMultiDocumentRequest? {
        let references = AndroidSpecialDocumentIdentity.parseBookAndKeyListReference(pageKey)
        guard !references.isEmpty, let pageKey else { return nil }

        var fragments: [OsisFragment] = []
        var hasStrongsOrMorphologyContent = false
        for reference in references {
            guard let restoredFragment = restoredFragment(for: reference) else {
                continue
            }
            fragments.append(restoredFragment.fragment)
            hasStrongsOrMorphologyContent = hasStrongsOrMorphologyContent || restoredFragment.usesStrongsContentType
        }
        guard !fragments.isEmpty else { return nil }

        let renderedKey = hasStrongsOrMorphologyContent
            ? AndroidSpecialDocumentIdentity.strongsRenderedKey
            : AndroidSpecialDocumentIdentity.multiRenderedKey
        let payload = MultiFragmentDocumentPayload(
            id: "multi-\(UUID().uuidString)",
            type: "multi",
            osisFragments: fragments,
            compare: false,
            contentType: hasStrongsOrMorphologyContent ? "strongs" : nil,
            state: nil
        )
        guard let data = try? bridgeEncoder.encode(payload),
              let documentJSON = String(data: data, encoding: .utf8) else {
            restoredMultiDocumentBuilderLogger.error("Failed to encode restored Android Multi bridge document")
            return nil
        }
        return BibleReaderRestoredMultiDocumentRequest(
            documentJSON: documentJSON,
            renderedKey: renderedKey,
            pageKey: pageKey
        )
    }

    /**
     Resolves one restored Android `BookAndKey` child into a Vue fragment.

     - Parameter reference: Parsed source document/key pair from the persisted `Multi` key.
     - Returns: A fragment and whether it should force Vue's Strong's document mode, or `nil` if
       the source document/key cannot be resolved.
     - Side effects: May read SWORD content and move source module cursors through restoring
       helpers.
     - Failure modes: Unavailable modules, invalid Bible references, or dictionary lookup misses
       return `nil`, mirroring Android's restored-child filtering behavior.
     */
    private func restoredFragment(
        for reference: AndroidSpecialDocumentIdentity.BookAndKeyReference
    ) -> (fragment: OsisFragment, usesStrongsContentType: Bool)? {
        let installedSource: BibleReaderInstalledModuleSource?
        if let documentInitials = reference.documentInitials {
            installedSource = moduleResolver.module(named: documentInitials)
        } else {
            installedSource = activeModuleName.flatMap(moduleResolver.module(named:))
        }

        if let scripture = installedSource?.scripture {
            return restoredBibleFragment(
                for: reference.key,
                source: scripture
            ).map { ($0, false) }
        }

        guard let dictionary = installedSource?.dictionary else { return nil }
        return restoredDictionaryFragment(
            for: reference.key,
            source: dictionary
        )
    }

    /**
     Builds one restored Bible fragment for Android `Multi` document restore.

     - Parameters:
       - persistedKey: Source passage saved in the Android `BookAndKey` child.
       - sourceModule: SWORD Bible module that owns the child key.
     - Returns: A Vue OSIS fragment preserving every source-canon verse and range in order, or
       `nil` if the source Bible cannot resolve the complete passage.
     - Side effects: Parses and reads the source passage while restoring the module cursor after
       exact-entry inspection.
     - Failure modes: Empty/malformed passages and partial source content return `nil` atomically.
     */
    private func restoredBibleFragment(
        for persistedKey: String,
        source: BibleReaderInstalledScriptureSource
    ) -> OsisFragment? {
        let parsedKeys: [String]
        switch source {
        case .sword(let module):
            parsedKeys = module.parseKeyList(persistedKey)
        case .sqlite:
            parsedKeys = persistedKey
                .split(whereSeparator: { $0 == "," || $0 == ";" })
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        guard let references = BibleReaderMultiReferenceDocumentBuilder.concreteReferences(
            parsedKeys: parsedKeys,
            source: source
        ) else { return nil }
        return BibleReaderInstalledScriptureFragmentBuilder.build(
            source: source,
            references: references,
            persistedOsisRef: persistedKey,
            requiresCompleteContent: true
        )
    }

    /**
     Builds one restored dictionary/glossary fragment for Android `Multi` document restore.

     - Parameters:
       - key: Persisted child key for the source dictionary or glossary module.
       - sourceModule: Installed source module that owns the key.
     - Returns: A Vue fragment plus whether the aggregate document should use Strong's mode.
     - Side effects: Reads the source module and restores its cursor through
       `BibleReaderStrongsDocumentBuilder.lookupInModule`.
     - Failure modes: Returns `nil` when the source module cannot resolve the key exactly enough to
       satisfy the dictionary lookup contract.
     */
    private func restoredDictionaryFragment(
        for key: String,
        source: BibleReaderInstalledDictionarySource
    ) -> (fragment: OsisFragment, usesStrongsContentType: Bool)? {
        let keyOptions = restoredDictionaryLookupKeys(for: key, source: source)
        guard let lookup = source.lookup(keyOptions: keyOptions) else {
            return nil
        }
        let isStrongsDefinition = source.info.features.contains(.hebrewDef)
            || source.info.features.contains(.greekDef)
        let isMorphologyDefinition = source.info.features.contains(.hebrewParse)
            || source.info.features.contains(.greekParse)
        let keyName = isStrongsDefinition
            ? BibleReaderStrongsDocumentBuilder.canonicalStrongsKeyName(
                requested: key,
                actualKey: lookup.actualKey,
                rawEntry: lookup.rawEntry
            )
            : lookup.actualKey
        let features = restoredDictionaryFeatures(for: source, keyName: keyName)
        let strongsLinkPrefix = BibleReaderStrongsDocumentBuilder.strongsLinkPrefix(forModuleName: source.info.name)
            ?? BibleReaderStrongsDocumentBuilder.strongsLinkPrefix(for: key)
        let xml = lookup.isNativeHtml
            ? BibleReaderStrongsDocumentBuilder.buildDictionaryEntryHTML(
                renderedText: lookup.renderedText,
                strongsLinkPrefix: strongsLinkPrefix
            )
            : BibleReaderStrongsDocumentBuilder.buildDictionaryEntryXML(
                rawEntry: lookup.rawEntry,
                renderedText: lookup.renderedText,
                fallbackTitle: keyName,
                strongsLinkPrefix: strongsLinkPrefix
            )
        let fragment = OsisFragment(
            xml: xml,
            key: "\(source.info.name)--\(keyName)",
            keyName: keyName,
            v11n: source.versificationName,
            bookCategory: DocumentCategory.dictionary.rawValue,
            bookInitials: source.info.name,
            bookAbbreviation: source.abbreviation,
            osisRef: keyName,
            isNewTestament: false,
            features: features,
            hasStrongs: features.type != nil,
            ordinalRange: nil,
            language: source.info.language.isEmpty ? "en" : source.info.language,
            direction: source.info.isRightToLeft ? "rtl" : "ltr",
            isNativeHtml: lookup.isNativeHtml
        )
        return (fragment, isStrongsDefinition || isMorphologyDefinition)
    }

    /**
     Chooses lookup keys for a restored dictionary child.

     Strong's modules need the same key-family expansion used by live Strong's links because
     persisted Android keys may be numeric while local modules expect prefixed or zero-stripped
     variants. Plain dictionaries use the persisted key directly, matching Android's
     `book.getKey(savedKey)` restore.

     - Parameters:
       - key: Persisted child key from Android's `BookAndKeyList.osisRef`.
       - sourceModule: Dictionary or glossary module that owns the key.
     - Returns: Ordered lookup candidates to try against `sourceModule`.
     - Side effects: None.
     - Failure modes: None; lookup failure is handled by the caller.
     */
    private func restoredDictionaryLookupKeys(
        for key: String,
        source: BibleReaderInstalledDictionarySource
    ) -> [String] {
        if source.info.features.contains(.hebrewDef)
            || source.info.features.contains(.greekDef) {
            return BibleReaderStrongsDocumentBuilder.strongsLookupKeyOptions(for: key)
        }
        return [key]
    }

    /**
     Maps restored dictionary module features into Vue `OsisFeatures`.

     - Parameters:
       - sourceModule: Dictionary/glossary module that produced the fragment.
       - keyName: Canonical key name resolved from the source module.
     - Returns: Feature metadata for Strong's dictionaries, or an empty feature set for plain
       dictionaries and morphology modules.
     - Side effects: None.
     - Failure modes: None.
     */
    private func restoredDictionaryFeatures(
        for source: BibleReaderInstalledDictionarySource,
        keyName: String
    ) -> OsisFeatures {
        if source.info.features.contains(.hebrewDef) {
            return OsisFeatures(type: "hebrew", keyName: keyName)
        }
        if source.info.features.contains(.greekDef) {
            return OsisFeatures(type: "greek", keyName: keyName)
        }
        return OsisFeatures()
    }
}
