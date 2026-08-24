import CLibSword
import Foundation

/**
 Identifies why an exact SWORD entry could not be projected as Android-compatible OSIS.

 These failures are intentionally semantic. Callers must surface no-content or malformed-content
 states instead of retrying with SWORD's rendered HTML, because rendered fallback loses OSIS links,
 dictionary structure, and generic-book bookmark anchors.
 */
public enum SwordRawOSISFragmentError: Error, Equatable, LocalizedError, Sendable {
    /// The requested module category is not one of Android's generic/commentary document paths.
    case unsupportedCategory(ModuleCategory)
    /// The caller supplied a key that cannot identify an exact module entry.
    case invalidKey(String)
    /// SWORD normalized the requested key to a different entry.
    case keyNotFound(requested: String, resolved: String)
    /// The source entry could not be parsed as the XML emitted by JSword's OSIS pipeline.
    case malformedOSIS(key: String, reason: String)
    /// A commentary-category dictionary entry contains no direct verse for Android to unwrap.
    case missingCommentaryVerse(key: String, keyName: String, osisRef: String)
    /// The requested native module is not represented by JSword as a `SwordDictionary`.
    case unsupportedDictionaryDriver(String)
    /// The requested native module is not represented by JSword as a `SwordGenBook`.
    case unsupportedGenBookDriver(String)

    /// Human-readable diagnostic suitable for logs and reader error documents.
    public var errorDescription: String? {
        switch self {
        case .unsupportedCategory(let category):
            return "Raw OSIS is not available for SWORD category \(category.rawValue)."
        case .invalidKey(let key):
            return "The SWORD key '\(key)' is not valid for this document."
        case .keyNotFound(let requested, let resolved):
            return "The SWORD key '\(requested)' resolved to '\(resolved)' instead of an exact entry."
        case .malformedOSIS(let key, let reason):
            return "The SWORD entry '\(key)' contains malformed OSIS: \(reason)"
        case .missingCommentaryVerse(let key, _, _):
            return "The SWORD commentary entry '\(key)' has no direct verse element."
        case .unsupportedDictionaryDriver(let driver):
            return "The SWORD driver '\(driver)' is not a JSword SwordDictionary backend."
        case .unsupportedGenBookDriver(let driver):
            return "The SWORD driver '\(driver)' is not a JSword SwordGenBook backend."
        }
    }
}

/**
 Stable source metadata carried by every generic SWORD fragment.

 Android attaches the originating `Book` to both `OsisFragment` and generic bookmarks. Keeping the
    same identity beside the XML prevents dictionary/general/map/commentary content from silently
 inheriting the active Bible's initials, name, language, direction, or versification.
 */
public struct SwordRawOSISSource: Equatable, Sendable {
    /// Installed module initials, such as `StrongsGreek` or `MHC`.
    public let initials: String
    /// Human-readable module name.
    public let name: String
    /// Compact module abbreviation from SWORD metadata, falling back to initials.
    public let abbreviation: String
    /// Android/JSword document category.
    public let category: ModuleCategory
    /// ISO language code used by the renderer and sentence parser.
    public let language: String
    /// `ltr` or `rtl`, matching Android's bridge contract.
    public let direction: String
    /// SWORD versification name. Generic SWORD books inherit JSword's KJV default when omitted.
    public let versification: String
    /// Whether the source advertises Strong's-number markup.
    public let hasStrongs: Bool
    /// SWORD feature flags needed to project Android dictionary metadata.
    public let moduleFeatures: ModuleFeatures
}

/**
 One exact SWORD entry represented as canonical, anchored OSIS.

 `originalXML` is the source-format-to-OSIS conversion before BibleView anchors are inserted;
 `xml` is the immutable reader fragment containing Android-compatible `BVA` ordinals. The two
 ordinal domains are kept separate: `keyOrdinalRange` identifies a verse-key entry, while
 `contentOrdinalRange` identifies generic selected-text anchors inside that entry.
 */
public struct SwordRawOSISFragment: Equatable, Sendable {
    /// Canonical OSIS with Android-compatible `BVA` anchors.
    public let xml: String
    /// Canonical OSIS before `BVA` anchors are inserted.
    public let originalXML: String
    /// Exact module key used to read the entry.
    public let key: String
    /// Human-readable key name.
    public let keyName: String
    /// Module-qualified fragment identity used by Android/Vue.
    public let fragmentKey: String
    /// OSIS reference for the exact key.
    public let osisRef: String
    /// Originating module metadata.
    public let source: SwordRawOSISSource
    /// Whether a verse-key entry belongs to the New Testament.
    public let isNewTestament: Bool
    /// Android dictionary feature metadata (`type` and `keyName`) when applicable.
    public let features: [String: String]
    /// Inclusive local `BVA` range used by generic bookmarks; empty text uses Android's `0...0`.
    public let contentOrdinalRange: ClosedRange<Int>
    /// Inclusive source-versification range for verse-key entries.
    public let keyOrdinalRange: ClosedRange<Int>?
    /// Optional annotation target declared by the source OSIS.
    public let annotateRef: String?
    /// Text for each local `BVA` ordinal, preserving source order and whitespace.
    public let anchorTexts: [Int: String]
    /// Android-compatible semantic plain text used to compare commentary blocks.
    public let comparablePlainText: String?
    /// Whether the fragment contains any structural or textual source content.
    public let hasRenderableContent: Bool

    /**
     Returns source text for an inclusive local anchor range.

     - Parameter range: `BVA` ordinals selected in this exact entry.
     - Returns: Text values in ordinal order; missing ordinals are omitted exactly like Android's
       `getTextWithinOrdinalsAsString`.
     - Side effects: None.
     - Failure modes: None; an out-of-range selection returns an empty array.
     */
    public func text(in range: ClosedRange<Int>) -> [String] {
        range.compactMap { anchorTexts[$0] }
    }
}

/**
 Android-equivalent dictionary chooser presentation for one exact lexicon key.
 */
public struct SwordDictionaryEntryPresentation: Equatable, Sendable {
    /// Exact dictionary key selected from the module's global key list.
    public let key: String
    /// Preferred orthography or cleaned entry snippet.
    public let snippet: String
    /// Visible chooser row (`key - snippet`, or just `key` when no snippet exists).
    public let displayText: String

    /**
     Creates one immutable dictionary chooser row.

     - Parameters:
       - key: Exact module key.
       - snippet: Android-derived orthography or cleaned snippet.
       - displayText: Composed visible row text.
     - Side effects: None.
     - Failure modes: None.
     */
    public init(key: String, snippet: String, displayText: String) {
        self.key = key
        self.snippet = snippet
        self.displayText = displayText
    }
}

public extension SwordRawOSISFragment {
    /**
     Derives the chooser row Android's `ChooseDictionaryWord.KeyInfo` displays.

     - Returns: Exact key, orthography/snippet, and composed display text.
     - Side effects: Parses `originalXML` without mutating the fragment.
     - Failure modes: Returns a key-only row if the preserved XML cannot be reparsed. The entry
       loader itself still reports malformed OSIS; this defensive path keeps a chooser dismissible.
     */
    func dictionaryEntryPresentation() -> SwordDictionaryEntryPresentation {
        let snippet = (try? SwordOSISFragmentProcessor.dictionarySnippet(
            xml: originalXML,
            key: key
        )) ?? ""
        return SwordDictionaryEntryPresentation(
            key: key,
            snippet: snippet,
            displayText: snippet.isEmpty ? keyName : "\(keyName) - \(snippet)"
        )
    }
}

public extension SwordModule {
    /**
     Reads one exact dictionary, general-book, map, devotional, glossary, or commentary entry as
     canonical OSIS without using rendered HTML.

     Android obtains these documents through `BookData.osisFragment`, then adds stable `BVA`
     anchors for selected-text bookmarks. This API mirrors that boundary: it decodes native source,
     converts the declared source type through the shared pinned JSword filter, verifies that SWORD did not snap to a
     neighboring key, restores the previous cursor, and adds anchors to structured XML.

     - Parameter keyText: Exact key from the module global key list, or an exact OSIS verse for a
       commentary.
     - Returns: Immutable source metadata, canonical XML, local anchors, and verse-key metadata.
     - Side effects: Temporarily moves the module cursor while holding `SwordRuntime`, then restores
       the prior key before returning.
     - Failure modes: Throws for unsupported categories, invalid/non-exact keys, or malformed XML.
       Empty exact entries return an empty `<div/>` fragment so callers can apply Android's
       deterministic no-content behavior.
     */
    func rawOSISFragment(forKey keyText: String) throws -> SwordRawOSISFragment {
        try rawOSISFragment(
            forKey: keyText,
            insertsGeneratedDictionaryTitle: false,
            usesDriverOwnedGenericKey: false
        )
    }

    /**
     Reads one exact native `SwordDictionary` entry with its generated title and BVA anchors.

     Android inserts the resolved key title before the source-filtered dictionary body and processes
     the combined tree once. This narrow API keeps existing generic/commentary callers unchanged
     while allowing Strong's and word-lookup routes to preserve structured links, an exact empty
     title-only entry, and continuous title/body ordinal numbering.

     - Parameter keyText: Exact backend-selected RawLD/zLD key from the source index.
     - Returns: Immutable source metadata and payload-ready anchored dictionary OSIS.
     - Side effects: Temporarily moves the module cursor under `SwordRuntime` and restores it.
     - Failure modes: Throws for non-dictionary drivers, non-exact keys, backend conversion failures,
       or malformed source OSIS.
     */
    func rawDictionaryOSISFragment(forKey keyText: String) throws -> SwordRawOSISFragment {
        let driver = info.moduleDriver
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard ["rawld", "rawld4", "zld"].contains(driver) else {
            throw SwordRawOSISFragmentError.unsupportedDictionaryDriver(info.moduleDriver)
        }
        return try rawOSISFragment(
            forKey: keyText,
            insertsGeneratedDictionaryTitle: true,
            usesDriverOwnedGenericKey: true
        )
    }

    /**
     Reads one JSword-selected RawLD-family record by physical source-index position.

     A stored dictionary can contain distinct keys that libsword collapses after case or Strong's
     padding normalization. Android selects the first matching physical RawLD index record; this
     boundary preserves that record identity and asks the shared Android-compatible source filter to
     process its exact body without performing a second ambiguous key search.

     - Parameters:
       - index: Zero-based physical index returned by the JSword-compatible search.
       - storedKey: Exact decoded key at that index, used for fragment identity and generated title.
     - Returns: Payload-ready dictionary OSIS with actual source metadata and hidden generated title.
     - Side effects: Reads/caches the fixed-width source index, temporarily changes the native key
       used as filter context, and restores the previous key under `SwordRuntime` serialization.
     - Failure modes: Throws for unsupported drivers, changed/mismatched slots, zero-size records,
       contained-file read failures, native decompression/shared conversion failures, or malformed
       OSIS.
     */
    func rawDictionaryOSISFragment(
        forIndex index: Int,
        storedKey: String
    ) throws -> SwordRawOSISFragment {
        let driver = info.moduleDriver
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard ["rawld", "rawld4", "zld"].contains(driver) else {
            throw SwordRawOSISFragmentError.unsupportedDictionaryDriver(info.moduleDriver)
        }
        guard let slots = try loadRawDictionaryIndexSlots(),
              slots.indices.contains(index),
              let slotKey = slots[index].key,
              slotKey == storedKey,
              slots[index].size > 0 else {
            throw SwordRawOSISFragmentError.keyNotFound(requested: storedKey, resolved: "")
        }
        let slot = slots[index]
        let rawRecord = driver == "zld" ? nil : try rawDictionaryRecord(for: slot)

        let capture: RawOSISEntryCapture = SwordRuntime.sync {
            let previousKey = String(cString: SWModule_getKeyText(handle))
            defer { SWModule_setKeyText(handle, previousKey) }
            SWModule_setKeyText(handle, storedKey)

            let decodedSource: String = rawRecord?.withUnsafeBytes { bytes in
                let pointer = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self)
                return SWModule_getRawDictionaryDecodedSourceAtIndex(
                    handle,
                    Int(index),
                    pointer,
                    UInt(bytes.count)
                ).map(String.init(cString:)) ?? ""
            } ?? SWModule_getRawDictionaryDecodedSourceAtIndex(
                handle,
                Int(index),
                nil,
                0
            ).map(String.init(cString:)) ?? ""

            let converted = SwordSourceFormatOSISConverter.fragment(
                handle: handle,
                decodedSource: decodedSource
            )

            let abbreviation = Self.nonEmptyConfigValue(handle: handle, key: "Abbreviation") ?? info.name
            let versification = info.aboutMetadata.versification.isEmpty
                ? "KJV"
                : info.aboutMetadata.versification
            return RawOSISEntryCapture(
                xml: converted,
                key: storedKey,
                keyName: storedKey,
                osisRef: storedKey,
                source: SwordRawOSISSource(
                    initials: info.name,
                    name: info.description,
                    abbreviation: abbreviation,
                    category: info.category,
                    language: info.language,
                    direction: info.isRightToLeft ? "rtl" : "ltr",
                    versification: versification,
                    hasStrongs: info.features.contains(.strongsNumbers),
                    moduleFeatures: info.features
                ),
                keyOrdinalRange: nil,
                isNewTestament: false
            )
        }
        return try processedRawOSISFragment(
            capture: capture,
            insertsGeneratedDictionaryTitle: true,
            usesDriverOwnedGenericKey: true,
            genBookTreeKeyCardinality: nil
        )
    }

    /**
     Reads one exact native `SwordGenBook` TreeKey under its actual configured category.

     - Parameters:
       - keyText: Exact backend-selected full TreeKey path from the module key map.
       - treeKeyCardinality: Selected TreeKey plus descendants, derived from the activated key map.
     - Returns: Immutable actual-key metadata and category-processed payload-ready OSIS.
     - Side effects: Temporarily moves the module cursor under `SwordRuntime` and restores it.
     - Failure modes: Throws for a non-RawGenBook driver, non-exact key, malformed OSIS, or a
       Commentary-configured leaf entry without Android's required direct verse.
     */
    func rawGenBookOSISFragment(
        forKey keyText: String,
        treeKeyCardinality: Int
    ) throws -> SwordRawOSISFragment {
        let driver = info.moduleDriver
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard driver == "rawgenbook" else {
            throw SwordRawOSISFragmentError.unsupportedGenBookDriver(info.moduleDriver)
        }
        return try rawOSISFragment(
            forKey: keyText,
            insertsGeneratedDictionaryTitle: false,
            usesDriverOwnedGenericKey: true,
            genBookTreeKeyCardinality: treeKeyCardinality
        )
    }

    /**
     Captures and processes one exact source entry under the requested JSword document contract.

     - Parameters:
       - keyText: Exact source key.
       - insertsGeneratedDictionaryTitle: Whether to prepend `SwordDictionary`'s hidden key title
         before the one OSIS processor pass.
       - usesDriverOwnedGenericKey: Whether a validated dictionary/GenBook driver owns key type
         independently from configured category.
       - genBookTreeKeyCardinality: Selected TreeKey subtree size for Android's Commentary branch.
     - Returns: Immutable processed fragment and exact source metadata.
     - Side effects: Temporarily moves and restores the module cursor under `SwordRuntime`.
     - Failure modes: Propagates the public raw-fragment semantic errors.
     */
    private func rawOSISFragment(
        forKey keyText: String,
        insertsGeneratedDictionaryTitle: Bool,
        usesDriverOwnedGenericKey: Bool,
        genBookTreeKeyCardinality: Int? = nil
    ) throws -> SwordRawOSISFragment {
        guard usesDriverOwnedGenericKey || Self.rawOSISCategories.contains(info.category) else {
            throw SwordRawOSISFragmentError.unsupportedCategory(info.category)
        }

        let capture: RawOSISEntryCapture = try SwordRuntime.sync {
            let previousKey = String(cString: SWModule_getKeyText(handle))
            defer { SWModule_setKeyText(handle, previousKey) }

            let requestedKey = keyText
            guard !requestedKey.isEmpty else {
                throw SwordRawOSISFragmentError.invalidKey(keyText)
            }

            let actualKey: String
            let keyName: String
            let osisRef: String
            let keyOrdinalRange: ClosedRange<Int>?
            let isNewTestament: Bool
            let osis: String

            if !usesDriverOwnedGenericKey, info.category == .commentary {
                guard let requestedVerse = SwordOSISVerseAddress(keyText: requestedKey) else {
                    throw SwordRawOSISFragmentError.invalidKey(keyText)
                }
                SWModule_setKeyText(handle, "=\(requestedVerse.osisRef)")
                guard let children = Self.rawOSISVerseKeyChildren(handle: handle) else {
                    throw SwordRawOSISFragmentError.keyNotFound(
                        requested: requestedKey,
                        resolved: String(cString: SWModule_getKeyText(handle))
                    )
                }
                let resolvedVerse = SwordOSISVerseAddress(
                    osisBookId: children.osisBookName,
                    chapter: children.chapter,
                    verse: children.verse
                )
                guard resolvedVerse == requestedVerse else {
                    throw SwordRawOSISFragmentError.keyNotFound(
                        requested: requestedKey,
                        resolved: children.osisRef
                    )
                }
                actualKey = children.osisRef
                keyName = children.shortText.isEmpty ? children.osisRef : children.shortText
                osisRef = children.osisRef
                keyOrdinalRange = children.index...children.index
                isNewTestament = children.testament == 2
                osis = SwordSourceFormatOSISConverter.fragment(handle: handle)
            } else {
                SWModule_setKeyText(handle, requestedKey)
                // RawLD/TreeKey modules finalize their snapped key while loading the entry.
                osis = SwordSourceFormatOSISConverter.fragment(handle: handle)
                let resolvedKey = String(cString: SWModule_getKeyText(handle))
                guard resolvedKey == requestedKey else {
                    throw SwordRawOSISFragmentError.keyNotFound(
                        requested: requestedKey,
                        resolved: resolvedKey
                    )
                }
                actualKey = resolvedKey
                let currentKeyName = SWModule_getCurrentKeyName(handle).map(String.init(cString:)) ?? ""
                keyName = currentKeyName.isEmpty ? resolvedKey : currentKeyName
                osisRef = resolvedKey
                keyOrdinalRange = nil
                isNewTestament = false
            }

            let abbreviation = Self.nonEmptyConfigValue(handle: handle, key: "Abbreviation") ?? info.name
            let versification = info.aboutMetadata.versification.isEmpty
                ? "KJV"
                : info.aboutMetadata.versification
            let source = SwordRawOSISSource(
                initials: info.name,
                name: info.description,
                abbreviation: abbreviation,
                category: info.category,
                language: info.language,
                direction: info.isRightToLeft ? "rtl" : "ltr",
                versification: versification,
                hasStrongs: info.features.contains(.strongsNumbers),
                moduleFeatures: info.features
            )
            return RawOSISEntryCapture(
                xml: osis,
                key: actualKey,
                keyName: keyName,
                osisRef: osisRef,
                source: source,
                keyOrdinalRange: keyOrdinalRange,
                isNewTestament: isNewTestament
            )
        }

        return try processedRawOSISFragment(
            capture: capture,
            insertsGeneratedDictionaryTitle: insertsGeneratedDictionaryTitle,
            usesDriverOwnedGenericKey: usesDriverOwnedGenericKey,
            genBookTreeKeyCardinality: genBookTreeKeyCardinality
        )
    }

    /**
     Applies actual-category document processing and assembles immutable fragment metadata.

     - Parameters:
       - capture: Exact source XML and resolved book/key metadata.
       - insertsGeneratedDictionaryTitle: Whether to prepend SwordDictionary's hidden title.
       - usesDriverOwnedGenericKey: Whether category-independent RawLD/RawGenBook processing applies.
       - genBookTreeKeyCardinality: Selected TreeKey subtree size for Commentary behavior.
     - Returns: Canonical payload-ready OSIS and Android fragment identity.
     - Side effects: Parses and serializes copied XML only.
     - Failure modes: Maps missing Commentary verses to the typed fragment error and other processor
       failures to `malformedOSIS` with the exact selected key.
     */
    private func processedRawOSISFragment(
        capture: RawOSISEntryCapture,
        insertsGeneratedDictionaryTitle: Bool,
        usesDriverOwnedGenericKey: Bool,
        genBookTreeKeyCardinality: Int?
    ) throws -> SwordRawOSISFragment {
        do {
            let processed: SwordProcessedOSISFragment
            if insertsGeneratedDictionaryTitle {
                processed = try SwordOSISFragmentProcessor.processDictionarySource(
                    sourceXML: capture.xml,
                    keyName: capture.keyName,
                    moduleInitials: capture.source.initials,
                    category: capture.source.category
                )
            } else if usesDriverOwnedGenericKey {
                processed = try SwordOSISFragmentProcessor.processGenBookSource(
                    sourceXML: capture.xml,
                    moduleInitials: capture.source.initials,
                    category: capture.source.category,
                    treeKeyCardinality: genBookTreeKeyCardinality ?? 1
                )
            } else {
                processed = try SwordOSISFragmentProcessor.process(
                    sourceXML: capture.xml,
                    category: capture.source.category,
                    moduleInitials: capture.source.initials
                )
            }
            let uniqueID = SwordRawOSISIdentity.uniqueID(
                key: capture.key,
                keyOrdinalRange: capture.keyOrdinalRange
            )
            let fragmentKey = "\(capture.source.initials)--\(uniqueID)"
            return SwordRawOSISFragment(
                xml: processed.xml,
                originalXML: processed.originalXML,
                key: capture.key,
                keyName: capture.keyName,
                fragmentKey: fragmentKey,
                osisRef: capture.osisRef,
                source: capture.source,
                isNewTestament: capture.isNewTestament,
                features: Self.rawOSISFeatures(source: capture.source, keyName: capture.keyName),
                contentOrdinalRange: processed.contentOrdinalRange,
                keyOrdinalRange: capture.keyOrdinalRange,
                annotateRef: processed.annotateRef,
                anchorTexts: processed.anchorTexts,
                comparablePlainText: processed.comparablePlainText,
                hasRenderableContent: processed.hasRenderableContent
            )
        } catch SwordOSISProcessorError.missingCommentaryVerse {
            throw SwordRawOSISFragmentError.missingCommentaryVerse(
                key: capture.key,
                keyName: capture.keyName,
                osisRef: capture.osisRef
            )
        } catch {
            throw SwordRawOSISFragmentError.malformedOSIS(
                key: capture.key,
                reason: error.localizedDescription
            )
        }
    }

    /**
     Lists configured categories supported by the legacy category-owned generic OSIS path.

     - Returns: Every pinned non-Bible category whose ordinary SWORD reader uses a generic key.
     - Side effects: Allocates an immutable set on access.
     - Failure modes: Bible remains excluded because its verse-key path is separate. Validated
       RawLD/RawGenBook drivers bypass this list because JSword chooses their key class by driver.
     */
    private static var rawOSISCategories: Set<ModuleCategory> {
        [
            .commentary,
            .dictionary,
            .generalBook,
            .map,
            .dailyDevotion,
            .glossary,
            .questionable,
            .essays,
            .images,
        ]
    }

    /**
     Reads a non-empty config value while the caller owns the SWORD runtime lock.

     - Parameters:
       - handle: Current module handle.
       - key: SWORD config key.
     - Returns: Trimmed non-empty value, or `nil`.
     - Side effects: Reads module metadata.
     - Failure modes: Missing and blank values return `nil`.
     */
    private static func nonEmptyConfigValue(
        handle: UnsafeMutableRawPointer,
        key: String
    ) -> String? {
        guard let pointer = SWModule_getConfigEntry(handle, key) else { return nil }
        let value = String(cString: pointer).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /**
     Builds Android's Greek/Hebrew dictionary feature object.

     - Parameters:
       - source: Module feature metadata.
       - keyName: Display key associated with the feature object.
     - Returns: Empty metadata for ordinary documents, or Android's `type` and `keyName` fields.
     - Side effects: None.
     - Failure modes: None.
     */
    private static func rawOSISFeatures(
        source: SwordRawOSISSource,
        keyName: String
    ) -> [String: String] {
        let hasHebrew = source.moduleFeatures.contains(.hebrewDef)
        let hasGreek = source.moduleFeatures.contains(.greekDef)
        let type: String?
        switch (hasHebrew, hasGreek) {
        case (true, true):
            type = "hebrew-and-greek"
        case (true, false):
            type = "hebrew"
        case (false, true):
            type = "greek"
        case (false, false):
            type = nil
        }
        guard let type else { return [:] }
        return ["type": type, "keyName": keyName]
    }

    /**
     Copies direct VerseKey metadata while the caller owns the SWORD runtime lock.

     - Parameter handle: Commentary module handle positioned at an exact candidate verse.
     - Returns: Structured metadata and intro-inclusive index, or `nil` for a non-VerseKey/error.
     - Side effects: Reads SWORD's current key only.
     - Failure modes: Missing or malformed bridge values return `nil`.
     */
    private static func rawOSISVerseKeyChildren(
        handle: UnsafeMutableRawPointer
    ) -> VerseKeyChildren? {
        guard let children = SWModule_getKeyChildren(handle) else { return nil }
        var parts: [String] = []
        var index = 0
        while index < 11, let pointer = children[index] {
            parts.append(String(cString: pointer))
            index += 1
        }
        guard parts.count >= 8,
              let testament = Int(parts[0]),
              let book = Int(parts[1]),
              let chapter = Int(parts[2]),
              let verse = Int(parts[3]),
              let chapterMax = Int(parts[4]),
              let verseMax = Int(parts[5]) else {
            return nil
        }
        let keyIndex = SWModule_getVerseKeyIndex(handle)
        guard keyIndex >= 0 else { return nil }

        let osisRef = parts[7]
        let fallbackBook = osisRef.components(separatedBy: ".").first ?? osisRef
        return VerseKeyChildren(
            testament: testament,
            book: book,
            chapter: chapter,
            verse: verse,
            index: Int(keyIndex),
            chapterMax: chapterMax,
            verseMax: verseMax,
            bookName: parts[6],
            osisRef: osisRef,
            shortText: parts.count > 8 && !parts[8].isEmpty ? parts[8] : osisRef,
            bookAbbreviation: parts.count > 9 && !parts[9].isEmpty ? parts[9] : fallbackBook,
            osisBookName: parts.count > 10 && !parts[10].isEmpty ? parts[10] : fallbackBook
        )
    }
}

/** Android `Key.uniqueId` projection used by generic and commentary OSIS fragments. */
enum SwordRawOSISIdentity {
    /**
     Builds the stable fragment-local key consumed by BibleView.

     - Parameters:
       - key: Exact module key or OSIS reference.
       - keyOrdinalRange: VerseKey ordinal range when the key is passage-based.
     - Returns: Android's `ordinal-start-end` identity for passage keys, otherwise the exact key
       with every non-letter/non-digit scalar replaced by `_`.
     - Side effects: None.
     - Failure modes: None; empty keys are rejected before this boundary.
     */
    static func uniqueID(
        key: String,
        keyOrdinalRange: ClosedRange<Int>?
    ) -> String {
        if let keyOrdinalRange {
            return "ordinal-\(keyOrdinalRange.lowerBound)-\(keyOrdinalRange.upperBound)"
        }
        return key.replacingOccurrences(
            of: #"[^\p{L}\d]"#,
            with: "_",
            options: .regularExpression
        )
    }
}

/** Captured SWORD data copied out while the module cursor is serialized. */
private struct RawOSISEntryCapture {
    let xml: String
    let key: String
    let keyName: String
    let osisRef: String
    let source: SwordRawOSISSource
    let keyOrdinalRange: ClosedRange<Int>?
    let isNewTestament: Bool
}

/** Exact OSIS verse address used to reject SWORD nearest-key normalization. */
private struct SwordOSISVerseAddress: Equatable {
    let osisBookId: String
    let chapter: Int
    let verse: Int

    var osisRef: String { "\(osisBookId).\(chapter).\(verse)" }

    init(osisBookId: String, chapter: Int, verse: Int) {
        self.osisBookId = osisBookId
        self.chapter = chapter
        self.verse = verse
    }

    init?(keyText: String) {
        let pattern = #"^=?([1-4]?[A-Za-z][A-Za-z0-9]*)[ .]+([0-9]+)[:.]([0-9]+)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: keyText,
                range: NSRange(location: 0, length: (keyText as NSString).length)
              ),
              match.range.location != NSNotFound,
              let bookRange = Range(match.range(at: 1), in: keyText),
              let chapterRange = Range(match.range(at: 2), in: keyText),
              let verseRange = Range(match.range(at: 3), in: keyText),
              let chapter = Int(keyText[chapterRange]),
              let verse = Int(keyText[verseRange]),
              chapter > 0,
              verse > 0 else {
            return nil
        }
        self.init(
            osisBookId: String(keyText[bookRange]),
            chapter: chapter,
            verse: verse
        )
    }
}
