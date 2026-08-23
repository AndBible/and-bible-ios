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

    /// Android-owned localization lookup shared with Strong's live-document error projection.
    private let localizedString: BibleReaderStrongsDocumentBuilder.LocalizedString

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
        activeModule: SwordModule?,
        localizedString: @escaping BibleReaderStrongsDocumentBuilder.LocalizedString = bibleReaderAndroidDocumentLocalizedString
    ) {
        self.moduleResolver = BibleReaderInstalledModuleResolver(
            swordManager: swordManager,
            sqliteModules: []
        )
        self.activeModuleName = activeModule?.info.name
        self.localizedString = localizedString
    }

    /**
     Creates a restored-document builder from the pane's shared global module resolver.

     - Parameters:
       - moduleResolver: Captured Android-compatible installed-book registry used for concrete-class
         dispatch and exact global identity lookup.
       - activeModuleName: Current Bible initials used by persisted `null:` child references.
       - localizedString: Android resource lookup used when an actual commentary-backed key source
         returns the typed key-not-in-document failure.
     - Side effects: None during construction; content reads and localization occur in `build`.
     - Failure modes: Missing active or installed sources are represented by dropped children during
       `build`; the initializer itself does not fail or substitute a different source.
     */
    init(
        moduleResolver: BibleReaderInstalledModuleResolver,
        activeModuleName: String?,
        localizedString: @escaping BibleReaderStrongsDocumentBuilder.LocalizedString = bibleReaderAndroidDocumentLocalizedString
    ) {
        self.moduleResolver = moduleResolver
        self.activeModuleName = activeModuleName
        self.localizedString = localizedString
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

        guard let installedSource else { return nil }
        if let verseKeySource = installedSource.verseKeySource,
           let fragment = restoredBibleFragment(
               for: reference.key,
               source: verseKeySource
           ) {
            return (
                fragment,
                AndroidDictionaryFragmentMetadata.usesStrongsContentType(
                    installedSource.info.features
                )
            )
        }

        guard let dictionary = installedSource.explicitDictionaryKeySource else { return nil }
        return restoredDictionaryFragment(
            for: reference.key,
            source: dictionary
        )
    }

    /**
     Builds one restored Bible fragment for Android `Multi` document restore.

     - Parameters:
       - persistedKey: Source passage saved in the Android `BookAndKey` child.
       - source: Globally selected native or SQLite verse-key book that owns the child key.
     - Returns: A Vue OSIS fragment preserving every source-canon verse/range plus the actual
       installed book's category and feature metadata, or `nil` when the source cannot resolve the
       complete passage.
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
        guard var fragment = BibleReaderInstalledScriptureFragmentBuilder.build(
            source: source,
            references: references,
            persistedOsisRef: persistedKey,
            requiresCompleteContent: true
        ) else {
            return nil
        }
        fragment.bookCategory = AndroidDictionaryFragmentMetadata.bookCategoryName(
            for: source.info.category
        )
        fragment.features = AndroidDictionaryFragmentMetadata.features(
            from: source.info.features,
            keyName: fragment.keyName
        )
        fragment.hasStrongs = source.info.features.contains(.strongsNumbers)
        return fragment
    }

    /**
     Builds one restored dictionary/glossary fragment for Android `Multi` document restore.

     - Parameters:
       - key: Persisted child key for the source dictionary or glossary module.
       - source: Globally selected installed key source that owns the key.
     - Returns: A Vue fragment plus whether the aggregate document should use Strong's mode.
     - Side effects: Reads the source module and restores its cursor through
       `BibleReaderStrongsDocumentBuilder.lookupInModule`.
     - Failure modes: Returns `nil` when the source module's own `getKey` contract cannot resolve the
       single persisted key; LinkControl Strong-family aliases are never synthesized during restore.
     */
    private func restoredDictionaryFragment(
        for key: String,
        source: BibleReaderInstalledDictionarySource
    ) -> (fragment: OsisFragment, usesStrongsContentType: Bool)? {
        guard let lookup = source.lookup(keyOptions: [key]) else {
            return nil
        }
        let keyName = lookup.actualKey
        let features = AndroidDictionaryFragmentMetadata.features(
            from: source.info.features,
            keyName: keyName
        )
        let strongsLinkPrefix = BibleReaderStrongsDocumentBuilder.strongsLinkPrefix(forModuleName: source.info.name)
            ?? BibleReaderStrongsDocumentBuilder.strongsLinkPrefix(for: key)
        let xml: String
        if lookup.payloadFailure == .keyNotInDocument {
            xml = BibleReaderStrongsDocumentBuilder.keyNotInDocumentXML(
                keyName: keyName,
                moduleInitials: source.info.name,
                localizedString: localizedString
            )
        } else if let payloadReadyXML = lookup.payloadReadyXML {
            xml = payloadReadyXML
        } else if lookup.isNativeHtml {
            xml = BibleReaderStrongsDocumentBuilder.buildDictionaryEntryHTML(
                renderedText: lookup.renderedText,
                strongsLinkPrefix: strongsLinkPrefix
            )
        } else {
            xml = BibleReaderStrongsDocumentBuilder.buildDictionaryEntryXML(
                rawEntry: lookup.rawEntry,
                renderedText: lookup.renderedText,
                strongsLinkPrefix: strongsLinkPrefix
            )
        }
        let fragment = OsisFragment(
            xml: xml,
            key: AndroidDictionaryFragmentMetadata.fragmentKey(
                bookInitials: source.info.name,
                keyOsisID: lookup.osisID
            ),
            keyName: keyName,
            v11n: source.versificationName,
            bookCategory: AndroidDictionaryFragmentMetadata.bookCategoryName(
                for: source.info.category
            ),
            bookInitials: source.info.name,
            bookAbbreviation: source.abbreviation,
            osisRef: lookup.osisRef,
            isNewTestament: false,
            features: features,
            hasStrongs: source.info.features.contains(.strongsNumbers),
            ordinalRange: nil,
            language: source.info.language.isEmpty ? "en" : source.info.language,
            direction: source.info.isRightToLeft ? "rtl" : "ltr",
            isNativeHtml: lookup.isNativeHtml
        )
        return (
            fragment,
            AndroidDictionaryFragmentMetadata.usesStrongsContentType(source.info.features)
        )
    }
}
