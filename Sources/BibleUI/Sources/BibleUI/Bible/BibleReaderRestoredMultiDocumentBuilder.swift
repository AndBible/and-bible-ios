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

 - Side effects: Reads SWORD module content and may temporarily move module cursors through
   `SwordModule` inspection helpers that restore previous cursor state.
 - Failure modes: Returns `nil` when the persisted key is absent, malformed, references no
   installed source documents, or cannot be encoded. Individual bad children are dropped, matching
   Android's restored-child filtering behavior.
 - Note: The builder is deterministic for a fixed installed-module set and persisted key except for
   the generated `MultiDocument` id, which intentionally mirrors the transient document payloads.
 */
struct BibleReaderRestoredMultiDocumentBuilder {
    /// Resolves source modules named in Android `BookAndKey` children.
    private let swordManager: SwordManager?

    /// Active Bible module used for Android `null:` current-Bible children.
    private let activeModule: SwordModule?

    /// Active-versification-aware OSIS id to display-name lookup supplied by the controller.
    private let bookNameForOsisId: (String) -> String?

    /// Active-versification-aware testament classifier supplied by the controller.
    private let isNewTestament: (String) -> Bool

    /**
     Creates a restored-document builder for one reader pane.

     - Parameters:
       - swordManager: SWORD manager containing installed source modules.
       - activeModule: Active Bible module used by Android `null:` current-Bible references.
       - bookNameForOsisId: Closure that maps OSIS ids through the pane's active versification.
       - isNewTestament: Closure that classifies display book names through the same catalog.
     - Side effects: None during construction.
     - Failure modes: Missing SWORD state is handled by returning `nil` from `build(pageKey:)`.
     */
    init(
        swordManager: SwordManager?,
        activeModule: SwordModule?,
        bookNameForOsisId: @escaping (String) -> String?,
        isNewTestament: @escaping (String) -> Bool
    ) {
        self.swordManager = swordManager
        self.activeModule = activeModule
        self.bookNameForOsisId = bookNameForOsisId
        self.isNewTestament = isNewTestament
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
        let sourceModule: SwordModule?
        if let documentInitials = reference.documentInitials {
            sourceModule = swordManager?.module(named: documentInitials)
        } else {
            sourceModule = activeModule
        }

        if sourceModule?.info.category == .bible,
           let osisReference = parseOsisRef(reference.key) {
            return restoredBibleFragment(
                for: osisReference,
                sourceModule: sourceModule,
                sourceDocumentInitials: reference.documentInitials
            ).map { ($0, false) }
        }

        guard let sourceModule else { return nil }
        switch sourceModule.info.category {
        case .dictionary, .glossary:
            return restoredDictionaryFragment(
                for: reference.key,
                sourceModule: sourceModule
            )
        default:
            return nil
        }
    }

    /**
     Parses a persisted OSIS key into the shared reader reference value.

     - Parameter osis: OSIS verse key saved in one Android `BookAndKey` child.
     - Returns: Parsed reference coordinates, or `nil` if the key is not a single verse.
     - Side effects: None.
     - Failure modes: Malformed keys or unknown OSIS book ids return `nil` so restore can drop only
       the bad child.
     */
    private func parseOsisRef(_ osis: String) -> OsisRef? {
        let parts = osis.split(separator: ".").map(String.init)
        guard parts.count >= 3,
              let chapter = Int(parts[1]),
              let verse = Int(parts[2]) else {
            return nil
        }

        let osisId = parts[0]
        guard let book = bookNameForOsisId(osisId) else { return nil }
        return OsisRef(book: book, chapter: chapter, verse: verse, osisId: osisId)
    }

    /**
     Builds one restored Bible fragment for Android `Multi` document restore.

     - Parameters:
       - ref: Parsed OSIS verse reference from the saved child key.
       - sourceModule: SWORD Bible module that owns the child key.
       - sourceDocumentInitials: Persisted source initials. `nil` means Android's `null:` current
         Bible marker, so the active Bible module identity is used.
     - Returns: A Vue OSIS fragment, or `nil` if the source Bible cannot resolve the verse.
     - Side effects: Reads the SWORD verse and restores the source module cursor afterward.
     - Failure modes: Missing source module or missing verse ordinal returns `nil`.
     */
    private func restoredBibleFragment(
        for ref: OsisRef,
        sourceModule: SwordModule?,
        sourceDocumentInitials: String?
    ) -> OsisFragment? {
        guard let sourceModule else { return nil }
        let moduleName = sourceDocumentInitials ?? sourceModule.info.name
        guard let ordinal = sourceModule.verseOrdinal(
            osisBookId: ref.osisId,
            chapter: ref.chapter,
            verse: ref.verse
        ) else {
            return nil
        }
        let osisRef = "\(ref.osisId).\(ref.chapter).\(ref.verse)"
        return OsisFragment(
            xml: BibleReaderMultiReferenceDocumentBuilder.buildBibleMultiReferenceXML(
                ref: ref,
                module: sourceModule,
                ordinal: ordinal
            ),
            key: "\(moduleName)--\(osisRef)",
            keyName: ref.displayName,
            v11n: "KJVA",
            bookCategory: DocumentCategory.bible.rawValue,
            bookInitials: moduleName,
            bookAbbreviation: ref.osisId,
            osisRef: osisRef,
            isNewTestament: isNewTestament(ref.book),
            features: OsisFeatures(),
            hasStrongs: sourceModule.info.features.contains(.strongsNumbers),
            ordinalRange: [ordinal, ordinal],
            language: sourceModule.info.language.isEmpty ? "en" : sourceModule.info.language,
            direction: sourceModule.info.isRightToLeft ? "rtl" : "ltr"
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
        sourceModule: SwordModule
    ) -> (fragment: OsisFragment, usesStrongsContentType: Bool)? {
        let keyOptions = restoredDictionaryLookupKeys(for: key, sourceModule: sourceModule)
        guard let lookup = BibleReaderStrongsDocumentBuilder.lookupInModule(sourceModule, keyOptions: keyOptions) else {
            return nil
        }
        let isStrongsDefinition = sourceModule.info.features.contains(.hebrewDef)
            || sourceModule.info.features.contains(.greekDef)
        let isMorphologyDefinition = sourceModule.info.features.contains(.hebrewParse)
            || sourceModule.info.features.contains(.greekParse)
        let keyName = isStrongsDefinition
            ? BibleReaderStrongsDocumentBuilder.canonicalStrongsKeyName(
                requested: key,
                actualKey: lookup.actualKey,
                rawEntry: lookup.rawEntry
            )
            : lookup.actualKey
        let features = restoredDictionaryFeatures(for: sourceModule, keyName: keyName)
        let xml = BibleReaderStrongsDocumentBuilder.buildDictionaryEntryXML(
            rawEntry: lookup.rawEntry,
            renderedText: lookup.renderedText,
            fallbackTitle: keyName,
            strongsLinkPrefix: BibleReaderStrongsDocumentBuilder.strongsLinkPrefix(forModuleName: sourceModule.info.name)
                ?? BibleReaderStrongsDocumentBuilder.strongsLinkPrefix(for: key)
        )
        let fragment = OsisFragment(
            xml: xml,
            key: "\(sourceModule.info.name)--\(keyName)",
            keyName: keyName,
            v11n: "KJVA",
            bookCategory: DocumentCategory.dictionary.rawValue,
            bookInitials: sourceModule.info.name,
            bookAbbreviation: BibleReaderStrongsDocumentBuilder.moduleDisplayLabel(sourceModule),
            osisRef: keyName,
            isNewTestament: false,
            features: features,
            hasStrongs: features.type != nil,
            ordinalRange: [0, 0],
            language: sourceModule.info.language.isEmpty ? "en" : sourceModule.info.language,
            direction: sourceModule.info.isRightToLeft ? "rtl" : "ltr"
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
    private func restoredDictionaryLookupKeys(for key: String, sourceModule: SwordModule) -> [String] {
        if sourceModule.info.features.contains(.hebrewDef)
            || sourceModule.info.features.contains(.greekDef) {
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
    private func restoredDictionaryFeatures(for sourceModule: SwordModule, keyName: String) -> OsisFeatures {
        if sourceModule.info.features.contains(.hebrewDef) {
            return OsisFeatures(type: "hebrew", keyName: keyName)
        }
        if sourceModule.info.features.contains(.greekDef) {
            return OsisFeatures(type: "greek", keyName: keyName)
        }
        return OsisFeatures()
    }
}
