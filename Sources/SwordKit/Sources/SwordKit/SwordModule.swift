// SwordModule.swift — SWModule wrapper for SwordKit

import Foundation
import CLibSword

/// Structured VerseKey metadata for a module's current position.
public struct VerseKeyChildren: Sendable {
    public let testament: Int
    public let book: Int
    public let chapter: Int
    public let verse: Int
    /// SWORD/JSword-style versification ordinal including book and chapter intro slots.
    public let index: Int
    public let chapterMax: Int
    public let verseMax: Int
    public let bookName: String
    public let osisRef: String
    public let shortText: String
    public let bookAbbreviation: String
    public let osisBookName: String
}

/**
 A resolved verse reference from SWORD's active versification.

 The reader bridge needs the same category of answers Android receives from JSword's
 `Versification`: exact book/chapter/verse identity plus the intro-inclusive ordinal used by
 bookmarks, navigation, highlighting, memorization, and reference documents. This value is copied
 out of the SWORD module while the module cursor is protected by `SwordRuntime`, so callers can
 retain it without holding any SWORD-owned pointers.
 */
public struct VerseKeyReference: Sendable, Equatable {
    /// OSIS book identifier, such as `Gen`, `Ruth`, or `1Cor`.
    public let osisBookId: String

    /// One-based chapter number resolved by the module's versification.
    public let chapter: Int

    /// One-based verse number resolved by the module's versification.
    public let verse: Int

    /// SWORD/JSword-style versification ordinal including book and chapter intro slots.
    public let ordinal: Int

    /**
     Creates a copied verse reference for callers outside the SwordKit module.

     - Parameters:
       - osisBookId: OSIS book identifier, such as `Gen` or `1Cor`.
       - chapter: One-based chapter number.
       - verse: One-based verse number.
       - ordinal: SWORD/JSword-style versification ordinal.
     - Side effects: None.
     - Failure modes: None; callers are responsible for supplying values already validated by
       SWORD or by a documented no-module compatibility fallback.
     */
    public init(osisBookId: String, chapter: Int, verse: Int, ordinal: Int) {
        self.osisBookId = osisBookId
        self.chapter = chapter
        self.verse = verse
        self.ordinal = ordinal
    }

    /// Canonical OSIS reference for this verse.
    public var osisRef: String {
        "\(osisBookId).\(chapter).\(verse)"
    }
}

/**
 One exact Bible verse captured from SWORD's source-neutral OSIS and canonical-text filters.

 The copied strings never retain native pointers. Either content projection may be absent while the
 verse identity remains valid, matching Android's independent canonical-text and OSIS extraction.
 */
public struct SwordVerseSourceEntry: Equatable, Sendable {
    /// Exact source-versification reference resolved from the requested ordinal.
    public let reference: VerseKeyReference

    /// Source-format-neutral OSIS returned by the shared Android-compatible converter, when available.
    public let osisFragment: String?

    /// Canonical visible text returned by SWORD's strip-text filter, when available.
    public let canonicalText: String?
}

/**
 One bounded source-versification passage captured while holding a single SWORD cursor lease.
 */
public struct SwordVerseSourceRange: Equatable, Sendable {
    /// Addressable verses in source ordinal order; intro ordinals inside the span are omitted.
    public let entries: [SwordVerseSourceEntry]

    /// Inclusive source ordinal start validated before content inspection began.
    public let sourceOrdinalStart: Int

    /// Inclusive source ordinal end validated before content inspection began.
    public let sourceOrdinalEnd: Int

    /// Source-versification OSIS identity, including both endpoints for a multi-verse range.
    public let sourceOSISRange: String

    /// One Android-equivalent canonical projection over the complete source passage.
    public let canonicalText: String?
}

/** Fail-closed errors from bounded SWORD Bible source inspection. */
public enum SwordVerseSourceInspectionError: Error, Equatable, Sendable {
    /// One or both numeric endpoints cannot define a forward, positive verse span.
    case invalidRange

    /// The inclusive span exceeds the caller's work limit.
    case rangeTooLarge(maximumCount: Int)

    /// A supplied endpoint does not resolve to an exact normal verse in the module's versification.
    case nonAddressableEndpoint(Int)

    /// SWORD did not return to the exact key and verse index held before inspection.
    case cursorRestorationFailed
}

/** Immutable state used to prove that a composite SWORD read restored its caller's cursor. */
struct SwordModuleCursorSnapshot: Equatable, Sendable {
    /// Normalized key text copied before inspection.
    let keyText: String

    /// VerseKey index copied before inspection, or `nil` for a non-VerseKey cursor.
    let verseIndex: Int?

    /**
     Checks a restored cursor against both pieces of captured identity.

     - Parameters:
       - restoredKeyText: Key text after restoration.
       - restoredVerseIndex: VerseKey index after restoration, if present.
     - Returns: `true` only when key and index match the captured state exactly.
     - Side effects: None.
     - Failure modes: Missing or changed identity returns `false`.
     */
    func matches(restoredKeyText: String, restoredVerseIndex: Int?) -> Bool {
        keyText == restoredKeyText && verseIndex == restoredVerseIndex
    }
}

/** Projects one complete Bible source capture through Android's canonical-text state machine. */
private enum SwordBibleCanonicalTextProjection {
    /** Internal control-flow failure that selects the independent strip-text projection. */
    private enum ProjectionError: Error {
        case incompleteConvertedOSIS
    }

    /** Stateful output writer matching Android's cross-node whitespace handling. */
    private struct Writer {
        var output = ""
        var spaceJustWritten = true

        /** Starts a verse without trimming or rewriting output already emitted by earlier verses. */
        mutating func beginVerse() {
            spaceJustWritten = true
        }

        /** Ends a verse with Android's single canonical separator. */
        mutating func endVerse() {
            write(" ")
        }

        /**
         Appends one decoded SAX-style character chunk with Android's whitespace suppression.

         - Parameter value: One complete text or marker chunk from the source tree.
         - Side effects: Appends to `output` and updates cross-node whitespace state.
         - Failure modes: Empty values and redundant all-whitespace chunks are ignored.
         */
        mutating func write(_ value: String?) {
            guard let value, !value.isEmpty else { return }
            let decoded = SwordHTML4EntityDecoder.decode(value)
            guard !decoded.isEmpty else { return }
            if decoded.allSatisfy(\.isWhitespace) {
                guard !spaceJustWritten else { return }
                output.append(" ")
                spaceJustWritten = true
            } else {
                output.append(decoded)
                spaceJustWritten = decoded.last?.isWhitespace == true
            }
        }
    }

    /**
     Projects all converted verse fragments in one structured pass, with an independent strip-text
     fallback when converted OSIS is absent or malformed.

     - Parameter entries: Addressable source verses in exact passage order.
     - Returns: Android-compatible canonical text, including its final verse separator, or `nil`
       when neither complete source projection can produce text.
     - Side effects: Parses copied XML in memory; no SWORD cursor or native pointer is retained.
     - Failure modes: Malformed or partial OSIS selects the complete strip-text fallback. Missing
       values in both projections return `nil` without affecting structured OSIS publication.
     */
    static func project(_ entries: [SwordVerseSourceEntry]) -> String? {
        guard !entries.isEmpty else { return nil }
        if let sourceProjection = try? projectConvertedOSIS(entries), !sourceProjection.isEmpty {
            return sourceProjection
        }

        let canonicalPieces = entries.compactMap(\.canonicalText)
        guard canonicalPieces.count == entries.count else { return nil }
        var writer = Writer()
        for piece in canonicalPieces {
            writer.beginVerse()
            writer.write(piece)
            writer.endVerse()
        }
        return writer.output.isEmpty ? nil : writer.output
    }

    /**
     Builds one passage tree and walks canonical source nodes in document order.

     - Parameter entries: Complete source entries whose converted OSIS is independently optional.
     - Returns: One canonical passage projection, including Android's final verse separator.
     - Side effects: Parses copied XML fragments and allocates an in-memory passage tree.
     - Throws: XML parser failures or `ProjectionError` when any converted fragment is absent.
     */
    private static func projectConvertedOSIS(
        _ entries: [SwordVerseSourceEntry]
    ) throws -> String {
        let passage = SwordXMLNode.element(name: "div", attributes: [:])
        for entry in entries {
            guard let fragment = entry.osisFragment else {
                throw ProjectionError.incompleteConvertedOSIS
            }
            let parserRoot = try SwordXMLTreeParser.parse(
                xml: "<andbible-canonical-root>\(fragment)</andbible-canonical-root>"
            )
            let verse = SwordXMLNode.element(
                name: "verse",
                attributes: ["osisID": entry.reference.osisRef]
            )
            verse.children = parserRoot.children
            passage.children.append(verse)
        }

        var writer = Writer()
        walk(passage, writeContent: true, writer: &writer)
        return writer.output
    }

    /**
     Recursively applies Android canonical inclusion and marker rules to one source node.

     - Parameters:
       - node: Current source-tree node.
       - writeContent: Inclusion state inherited from the parent element.
       - writer: Passage-level canonical writer shared across the traversal.
     - Side effects: Appends included text/markers and mutates passage whitespace state.
     - Failure modes: None; malformed XML is rejected before traversal begins.
     */
    private static func walk(
        _ node: SwordXMLNode,
        writeContent: Bool,
        writer: inout Writer
    ) {
        guard node.isElement else {
            if writeContent, node.isTextLike {
                writer.write(node.stringValue)
            }
            return
        }

        let name = node.localName
        var childWrite = writeContent
        if node.attribute(named: "canonical") == "true" {
            childWrite = true
        } else {
            switch name {
            case "verse":
                writer.beginVerse()
                childWrite = true
            case "milestone":
                writer.write(node.attribute(named: "marker") ?? "")
                childWrite = false
            case "note", "title":
                childWrite = false
            case "q":
                writer.write(node.attribute(named: "marker") ?? "")
                childWrite = true
            case "l", "lb", "p":
                writer.write(" ")
            default:
                break
            }
        }

        for child in node.children {
            walk(child, writeContent: childWrite, writer: &writer)
        }
        if name == "verse" {
            writer.endVerse()
        }
    }
}

/**
 Describes a SWORD backend failure while enumerating or validating generic module keys.

 SWORD uses error code `1` as the ordinary out-of-bounds sentinel at the end of iteration. Other
 codes indicate that the backend could not complete the requested operation and must not be
 represented as an empty module or a missing key.

 Associated values identify the affected module, attempted key when applicable, and raw SWORD error
 code. The error is deterministic value data with no side effects; callers may present its localized
 description and retry the same operation after the backend becomes readable.
 */
public enum SwordModuleKeyAccessError: Error, Equatable, LocalizedError, Sendable {
    /// Key enumeration stopped because SWORD reported a non-terminal backend error.
    case keyListReadFailed(moduleName: String, errorCode: Int)

    /// Exact-key validation stopped because SWORD reported a non-terminal backend error.
    case exactKeyReadFailed(moduleName: String, key: String, errorCode: Int)

    /// RawLD's fixed-width source index or referenced data record could not be decoded safely.
    case rawDictionaryIndexReadFailed(moduleName: String)

    /// Key enumeration completed, but SWORD did not return to the caller's exact cursor.
    case cursorRestorationFailed(moduleName: String)

    /**
     Produces actionable diagnostic text for Android-equivalent key chooser error presentation.

     - Returns: Module/key context plus the raw SWORD error code, or `nil` only if a future case does
       not provide a description.
     - Side effects: None.
     - Failure modes: None for current cases; the message deliberately remains available to retry UI.
     */
    public var errorDescription: String? {
        switch self {
        case .keyListReadFailed(let moduleName, let errorCode):
            return "Could not read entries from \(moduleName) (SWORD error \(errorCode))."
        case .exactKeyReadFailed(let moduleName, let key, let errorCode):
            return "Could not verify entry \(key) in \(moduleName) (SWORD error \(errorCode))."
        case .rawDictionaryIndexReadFailed(let moduleName):
            return "Could not read the stored dictionary index for \(moduleName)."
        case .cursorRestorationFailed(let moduleName):
            return "Could not restore the previous entry position in \(moduleName)."
        }
    }
}

/**
 One physical RawLD-family index slot before libsword normalizes its stored key spelling.

 JSword's binary search observes both valid record keys and zero-size placeholder slots. Keeping the
 index position and size separate from the optional key lets the iOS resolver reproduce midpoint
 skipping without turning a valid empty-body entry into a missing record.
 */
public struct SwordRawDictionaryIndexSlot: Equatable, Sendable {
    /// Zero-based physical index position used to read the selected record without another search.
    public let index: Int

    /// Exact decoded DataEntry key, or `nil` only for a zero-size placeholder slot.
    public let key: String?

    /// Raw index size; a valid empty-body entry remains positive because its key header is present.
    public let size: Int

    /// Contained `.dat` byte offset used only by `SwordModule` for a selected RawLD/RawLD4 read.
    let dataOffset: Int?

    /**
     Creates a physical source-index slot for backend-independent JSword search resolution.

     This public initializer intentionally omits payload bytes: consumers may reproduce JSword's
     search over slot metadata, while only `SwordModule` can bind a winning slot back to contained
     RawLD source data.

     - Parameters:
       - index: Zero-based physical index position.
       - key: Exact decoded DataEntry key, or `nil` for a zero-size placeholder.
       - size: Raw index size; zero identifies a placeholder, while positive values include valid
         records whose definition body is empty.
     - Side effects: None.
     - Failure modes: None; callers constructing synthetic slots are responsible for preserving
       source order and coherent key/size pairs.
     */
    public init(index: Int, key: String?, size: Int) {
        self.init(index: index, key: key, size: size, dataOffset: nil)
    }

    /**
     Creates a source-index slot with optional module-owned payload bytes.

     - Parameters:
       - index: Zero-based physical source position.
       - key: Exact decoded key, or `nil` for a zero-size placeholder.
       - size: Raw index size.
       - dataOffset: Contained RawLD/RawLD4 `.dat` offset retained for one exact read; zLD and
         synthetic consumers keep this `nil` because their backends own payload access.
     - Side effects: None.
     - Failure modes: None; only the validated module loader calls this initializer in production.
     */
    init(index: Int, key: String?, size: Int, dataOffset: Int?) {
        self.index = index
        self.key = key
        self.size = size
        self.dataOffset = dataOffset
    }
}

/**
 Swift wrapper around a SWORD SWModule instance.

 Provides verse key navigation, text retrieval, and search capabilities.
 All operations are serialized through `SwordRuntime` since libsword and the flat bridge keep
 process-global state and are not thread-safe. Successful generic key enumeration is cached for this
 immutable module-handle lifetime; backend failures are not cached and remain retryable.

 Do not create instances directly — obtain them from `SwordManager.module(named:)`.
 */
public final class SwordModule: @unchecked Sendable {
    let handle: UnsafeMutableRawPointer

    /// Installed SWORD root used for config-backed source-index inspection.
    private let moduleRootPath: String?

    /// Module metadata.
    public let info: ModuleInfo

    /**
     Successful generic key snapshot shared by switch preflight and chooser presentation.

     Access is confined to `SwordRuntime.sync`, so the unchecked-sendable wrapper never races this
     mutable cache. `Array` copy-on-write lets callers retain the snapshot without another native
     traversal or eager buffer copy. Failures leave the value `nil` so Retry performs a fresh read.
     */
    private var cachedAllKeys: [String]?

    /// Physical RawLD-family slots cached independently from libsword's normalized cursor keys.
    private var cachedRawDictionaryIndexSlots: [SwordRawDictionaryIndexSlot]?

    /// Validated contained `.dat` URL used to read only the selected RawLD/RawLD4 record body.
    private var cachedRawDictionaryEntryURL: URL?

    /**
     Creates one native module wrapper from an already-resolved exact config when available.

     - Parameters:
       - handle: Native module handle owned by the creating `SwordManager`.
       - modulePath: Installed SWORD root used by later config-backed inspections.
       - parsedConfig: Config captured by the manager's one-pass registry enumeration. Passing it
         prevents a nested full-directory scan while preserving the exact metadata owner.
     - Side effects: Reads immutable native metadata and may read one config when no parsed value is
       supplied; no module cursor or content is changed.
     - Failure modes: Missing optional metadata falls back to the native handle's config entries.
     */
    init(
        handle: UnsafeMutableRawPointer,
        modulePath: String? = nil,
        parsedConfig: SwordModuleConfig? = nil
    ) {
        self.handle = handle
        self.moduleRootPath = modulePath

        self.info = SwordRuntime.sync {
            // Extract metadata once at init
            let name = String(cString: SWModule_getName(handle))
            let description = String(cString: SWModule_getDescription(handle))
            let typeStr = String(cString: SWModule_getType(handle))
            let language = String(cString: SWModule_getLanguage(handle))
            let modDrvPtr = SWModule_getConfigEntry(handle, "ModDrv")
            let modDrv = modDrvPtr != nil ? String(cString: modDrvPtr!) : ""
            let config = parsedConfig
                ?? modulePath.flatMap { SwordModuleConfig.read(name: name, modulePath: $0) }

            // Detect features by parsing the .conf file directly from disk.
            // SWORD's flat API getConfigEntry() only returns the FIRST value for
            // multi-value keys (Feature, GlobalOptionFilter), so modules like KJV
            // where StrongsNumbers isn't the first entry are missed. Reading the
            // .conf file catches ALL entries.
            let features = config?.features ?? SwordModule.detectFeatures(
                name: name, handle: handle, modulePath: modulePath
            )

            let cipherKey = SWModule_getConfigEntry(handle, "CipherKey")
            let isEncrypted = cipherKey != nil
            let directionPtr = SWModule_getConfigEntry(handle, "Direction")
            let direction = directionPtr != nil ? String(cString: directionPtr!) : "LtoR"
            let versionPtr = SWModule_getConfigEntry(handle, "Version")
            // JSword defaults a missing Version to 1.0; matching it keeps installed metadata equal
            // to catalog metadata for versionless modules so no phantom update is reported.
            let rawVersion = versionPtr.map { String(cString: $0) } ?? ""
            let versionStr = rawVersion.isEmpty ? "1.0" : rawVersion
            func configValue(_ key: String) -> String {
                guard let value = SWModule_getConfigEntry(handle, key) else { return "" }
                return String(cString: value)
            }
            let aboutMetadata = config?.aboutMetadata ?? ModuleAboutMetadata(
                about: configValue("About"),
                shortPromo: configValue("ShortPromo"),
                shortCopyright: configValue("ShortCopyright"),
                copyright: configValue("Copyright"),
                distributionLicense: configValue("DistributionLicense"),
                unlockInfo: configValue("UnlockInfo"),
                versification: configValue("Versification"),
                osisId: name,
                isBadDocument: SWModule_getConfigEntry(handle, "BadDocument") != nil,
                swordVersionDate: configValue("SwordVersionDate")
            )

            return ModuleInfo(
                name: name,
                description: description,
                category: ModuleCategory(typeString: typeStr, modDrv: modDrv),
                language: language,
                moduleDriver: modDrv,
                version: versionStr,
                isEncrypted: isEncrypted,
                isUnlocked: !isEncrypted || (cipherKey.map { String(cString: $0) } ?? "").isEmpty == false,
                features: features,
                isRightToLeft: direction == "RtoL",
                aboutMetadata: aboutMetadata
            )
        }
    }

    // MARK: - Key Navigation

    /**
     Set the current verse/key position.
     - Parameter keyText: A verse reference like "Gen 1:1" or a dictionary key.
     */
    public func setKey(_ keyText: String) {
        SwordRuntime.sync {
            SWModule_setKeyText(handle, keyText)
        }
    }

    /// Get the current key text.
    public func currentKey() -> String {
        SwordRuntime.sync {
            String(cString: SWModule_getKeyText(handle))
        }
    }

    /// Get structured VerseKey data for the current position when the module uses VerseKey.
    public func currentVerseKeyChildren() -> VerseKeyChildren? {
        SwordRuntime.sync {
            Self.currentVerseKeyChildren(handle: handle)
        }
    }

    /// Get the current SWORD VerseKey index for verse-key modules.
    public func currentVerseKeyIndex() -> Int? {
        SwordRuntime.sync {
            let index = SWModule_getVerseKeyIndex(handle)
            return index >= 0 ? Int(index) : nil
        }
    }

    /**
     Resolves a verse to the ordinal used by the module's active versification.

     Android gets these ordinals through JSword `Versification.getOrdinal(Verse)`. This method
     delegates to SWORD's native `VerseKey.getIndex()`, including intro slots for the Bible,
     testament, book, and chapter. The method uses exact-key syntax and validates the resolved key
     so a missing or out-of-range verse cannot silently normalize to a neighboring reference.

     - Parameters:
       - osisBookId: OSIS book identifier such as `Gen`, `Ruth`, or `1Cor`.
       - chapter: One-based chapter number.
       - verse: One-based verse number.
     - Returns: The versification ordinal, or `nil` when the reference cannot be resolved exactly.
     - Side effects: Temporarily moves the SWORD module cursor inside the serialization queue and
       restores the previous key before returning.
     - Important: Use this for reader bridge ordinals instead of arithmetic based on chapter and
       verse counts; those arithmetic schemes do not match JSword/SWORD versification semantics.
     */
    public func verseOrdinal(osisBookId: String, chapter: Int, verse: Int) -> Int? {
        guard chapter > 0, verse > 0, !osisBookId.isEmpty else { return nil }

        return SwordRuntime.sync {
            let previousKey = String(cString: SWModule_getKeyText(handle))
            defer { SWModule_setKeyText(handle, previousKey) }

            guard let children = exactVerseKeyChildrenLocked(
                osisBookId: osisBookId,
                chapter: chapter,
                verse: verse
            ) else {
                return nil
            }

            let index = SWModule_getVerseKeyIndex(handle)
            guard index >= 0, children.chapter > 0, children.verse > 0 else { return nil }
            return Int(index)
        }
    }

    /**
     Resolves a versification ordinal back to a concrete verse reference.

     Android can reverse-map bookmark and memorization ordinals through JSword's versification. This
     method provides the same boundary for iOS by positioning SWORD's native `VerseKey` with
     `setIndex(_:)`, reading structured key metadata, and then restoring the caller's prior cursor.
     When `osisBookId` is provided, the method rejects ordinals that resolve outside that book.

     - Parameters:
       - osisBookId: Optional OSIS book identifier that the ordinal must resolve within.
       - ordinal: SWORD/JSword-style versification ordinal.
     - Returns: A copied verse reference, or `nil` if the ordinal does not represent a normal
       verse for the requested book.
     - Side effects: Temporarily moves the SWORD module cursor inside the serialization queue and
       restores the previous key before returning.
     */
    public func verseReference(osisBookId: String? = nil, ordinal: Int) -> VerseKeyReference? {
        guard ordinal > 0 else { return nil }

        return SwordRuntime.sync {
            let previousKey = String(cString: SWModule_getKeyText(handle))
            defer { SWModule_setKeyText(handle, previousKey) }

            guard SWModule_setVerseKeyIndex(handle, CLong(ordinal)) == 0,
                  let children = Self.currentVerseKeyChildren(handle: handle),
                  children.chapter > 0,
                  children.verse > 0 else {
                return nil
            }

            let resolvedOsisBookId = children.osisBookName
            if let osisBookId, osisBookId != resolvedOsisBookId {
                return nil
            }

            let resolvedOrdinal = SWModule_getVerseKeyIndex(handle)
            guard Int(resolvedOrdinal) == ordinal else { return nil }
            return VerseKeyReference(
                osisBookId: resolvedOsisBookId,
                chapter: children.chapter,
                verse: children.verse,
                ordinal: Int(resolvedOrdinal)
            )
        }
    }

    /**
     Atomically inspects one verse key and restores the module's previous cursor.

     - Parameter keyText: SWORD key text to inspect, such as `=Gen.1.1`.
     - Returns: The resolved key text, structured VerseKey metadata when available, and raw OSIS
       entry captured at the resolved key.
     - Side effects: temporarily moves the SWORD module cursor inside one serialized queue block,
       then restores the cursor that was active before the call returns.
     - Failure modes: returns `nil` VerseKey metadata when the module is not positioned on a
       VerseKey or SWORD cannot expose structured key children.
     - Important: Use this instead of separate `setKey`, `currentVerseKeyChildren`, and `rawEntry`
       calls when the key metadata and raw entry must describe the same module position.
     */
    public func inspectVerseKeyAndRawEntryRestoringPrevious(
        _ keyText: String
    ) -> (actualKey: String, verseKey: VerseKeyChildren?, rawEntry: String) {
        SwordRuntime.sync {
            let previousKey = String(cString: SWModule_getKeyText(handle))
            SWModule_setKeyText(handle, keyText)
            let actualKey = String(cString: SWModule_getKeyText(handle))
            let verseKey = Self.currentVerseKeyChildren(handle: handle)
            let rawEntry = String(cString: SWModule_getRawEntry(handle))
            SWModule_setKeyText(handle, previousKey)
            return (actualKey, verseKey, rawEntry)
        }
    }

    /**
     Atomically captures one exact verse through the shared source-to-OSIS converter and restores the
     caller's complete cursor.

     JSword converts each backend's configured source type to OSIS before its structural repair and
     `SwordBook.addOSIS` projection. Reader callers must use this boundary instead of treating
     `getRawEntry` as OSIS, because ThML, GBF, TEI, and plain-text modules have distinct source
     semantics.

     - Parameter keyText: Exact SWORD verse key such as `=Gen.1.1` or an introduction key ending in
       verse zero.
     - Returns: Resolved key text, structured VerseKey metadata, and source-neutral OSIS. Missing or
       empty native content is returned as an empty fragment for the caller to reject or omit.
     - Side effects: Temporarily moves the native module cursor and runs SWORD decoding/options plus
       the shared Android-compatible source converter while holding the process-wide runtime gate.
     - Throws: `SwordVerseSourceInspectionError.cursorRestorationFailed` when SWORD cannot restore
       both the prior key text and VerseKey ordinal; no captured content is published in that case.
     - Important: The returned strings and metadata are copied before the runtime lease ends and do
       not retain native pointers.
     */
    public func inspectVerseKeyOSISSourceRestoringPrevious(
        _ keyText: String
    ) throws -> (actualKey: String, verseKey: VerseKeyChildren?, osisFragment: String) {
        try SwordRuntime.sync {
            let previousIndexValue = SWModule_getVerseKeyIndex(handle)
            let cursorSnapshot = SwordModuleCursorSnapshot(
                keyText: String(cString: SWModule_getKeyText(handle)),
                verseIndex: previousIndexValue >= 0 ? Int(previousIndexValue) : nil
            )

            SWModule_setKeyText(handle, keyText)
            let result = (
                actualKey: String(cString: SWModule_getKeyText(handle)),
                verseKey: Self.currentVerseKeyChildren(handle: handle),
                osisFragment: SwordSourceFormatOSISConverter.fragment(handle: handle)
            )

            SWModule_setKeyText(handle, cursorSnapshot.keyText)
            if let verseIndex = cursorSnapshot.verseIndex {
                _ = SWModule_setVerseKeyIndex(handle, CLong(verseIndex))
            }
            let restoredIndexValue = SWModule_getVerseKeyIndex(handle)
            let restoredIndex = restoredIndexValue >= 0 ? Int(restoredIndexValue) : nil
            guard cursorSnapshot.matches(
                restoredKeyText: String(cString: SWModule_getKeyText(handle)),
                restoredVerseIndex: restoredIndex
            ) else {
                throw SwordVerseSourceInspectionError.cursorRestorationFailed
            }
            return result
        }
    }

    /**
     Atomically captures requested Search fallback sources and restores the caller's cursor.

     - Parameters:
       - keyText: Exact SWORD verse key selected by candidate search or bounded iteration.
       - includeRenderedText: Whether to run the rendered-text filter for lexical fallback.
       - includeOSISFragment: Whether to run the source-neutral OSIS filter for preview projection.
     - Returns: Resolved key metadata and raw entry plus requested rendered/OSIS source forms copied
       while the same exact verse owns the native cursor; omitted forms are empty strings.
     - Side effects: Temporarily moves the module cursor and runs only requested filters while holding
       the process-wide SWORD runtime gate, then restores key text and VerseKey ordinal.
     - Throws: `SwordVerseSourceInspectionError.cursorRestorationFailed` when the complete caller
       cursor cannot be restored; no captured source is published in that case.
     */
    public func inspectVerseKeySearchSourceRestoringPrevious(
        _ keyText: String,
        includeRenderedText: Bool = true,
        includeOSISFragment: Bool = true
    ) throws -> (
        actualKey: String,
        verseKey: VerseKeyChildren?,
        rawEntry: String,
        renderedText: String,
        osisFragment: String
    ) {
        try SwordRuntime.sync {
            let previousIndexValue = SWModule_getVerseKeyIndex(handle)
            let cursorSnapshot = SwordModuleCursorSnapshot(
                keyText: String(cString: SWModule_getKeyText(handle)),
                verseIndex: previousIndexValue >= 0 ? Int(previousIndexValue) : nil
            )

            SWModule_setKeyText(handle, keyText)
            let result = (
                actualKey: String(cString: SWModule_getKeyText(handle)),
                verseKey: Self.currentVerseKeyChildren(handle: handle),
                rawEntry: String(cString: SWModule_getRawEntry(handle)),
                renderedText: includeRenderedText
                    ? String(cString: SWModule_getRenderText(handle))
                    : "",
                osisFragment: includeOSISFragment
                    ? SwordSourceFormatOSISConverter.fragment(handle: handle)
                    : ""
            )

            SWModule_setKeyText(handle, cursorSnapshot.keyText)
            if let verseIndex = cursorSnapshot.verseIndex {
                _ = SWModule_setVerseKeyIndex(handle, CLong(verseIndex))
            }
            let restoredIndexValue = SWModule_getVerseKeyIndex(handle)
            let restoredIndex = restoredIndexValue >= 0 ? Int(restoredIndexValue) : nil
            guard cursorSnapshot.matches(
                restoredKeyText: String(cString: SWModule_getKeyText(handle)),
                restoredVerseIndex: restoredIndex
            ) else {
                throw SwordVerseSourceInspectionError.cursorRestorationFailed
            }
            return result
        }
    }

    /**
     Atomically captures canonical source text for one verse and restores the previous cursor.

     Android AI context keeps the raw OSIS fragment and `getCanonicalText` projection together.
     Reading both inside one `SwordRuntime` block guarantees they describe the same exact key while
     leaving existing raw-only inspection callers on their cheaper contract.

     - Parameter keyText: Exact SWORD verse key such as `=Gen.1.1`.
     - Returns: Resolved key, structured VerseKey metadata, raw OSIS, and stripped canonical text.
     - Side effects: Temporarily moves the module cursor, runs SWORD's source text filter, and
       restores the prior key before returning.
     - Failure modes: Missing/non-VerseKey entries return `nil` metadata and empty source fields as
       reported by SWORD; callers must validate exact coordinates before accepting the content.
     */
    public func inspectVerseKeySourceRestoringPrevious(
        _ keyText: String
    ) -> (
        actualKey: String,
        verseKey: VerseKeyChildren?,
        rawEntry: String,
        strippedText: String
    ) {
        SwordRuntime.sync {
            let previousKey = String(cString: SWModule_getKeyText(handle))
            defer { SWModule_setKeyText(handle, previousKey) }
            SWModule_setKeyText(handle, keyText)
            return (
                actualKey: String(cString: SWModule_getKeyText(handle)),
                verseKey: Self.currentVerseKeyChildren(handle: handle),
                rawEntry: String(cString: SWModule_getRawEntry(handle)),
                strippedText: String(cString: SWModule_getStripText(handle))
            )
        }
    }

    /**
     Captures one bounded Bible passage through SWORD's source-neutral OSIS conversion.

     Both endpoints are resolved before any range walk. The method then inspects at most
     `maximumVerseCount` ordinals under one `SwordRuntime` lease, skips only non-verse intro slots,
     and restores the exact prior cursor before returning any copied result.

     - Parameters:
       - startOrdinal: Inclusive first ordinal in the module's own versification.
       - endOrdinal: Inclusive last ordinal in the module's own versification.
       - maximumVerseCount: Maximum inclusive ordinal span accepted by this operation.
     - Returns: Exact source identities plus independently optional OSIS and canonical text.
     - Side effects: Temporarily moves the module cursor while holding the process-wide SWORD gate.
     - Throws: `SwordVerseSourceInspectionError` for invalid, excessive, non-addressable, or
       non-restorable requests.
     */
    public func inspectVerseSourceRangeRestoringPrevious(
        startOrdinal: Int,
        endOrdinal: Int,
        maximumVerseCount: Int = 500
    ) throws -> SwordVerseSourceRange {
        try SwordRuntime.sync {
            let previousIndexValue = SWModule_getVerseKeyIndex(handle)
            let cursorSnapshot = SwordModuleCursorSnapshot(
                keyText: String(cString: SWModule_getKeyText(handle)),
                verseIndex: previousIndexValue >= 0 ? Int(previousIndexValue) : nil
            )

            let captureResult: Result<SwordVerseSourceRange, SwordVerseSourceInspectionError>
            if startOrdinal <= 0 || endOrdinal < startOrdinal || maximumVerseCount <= 0 {
                captureResult = .failure(.invalidRange)
            } else {
                let distance = endOrdinal - startOrdinal
                if distance >= maximumVerseCount {
                    captureResult = .failure(.rangeTooLarge(maximumCount: maximumVerseCount))
                } else {
                    let referenceAtOrdinal: (Int) -> VerseKeyReference? = { ordinal in
                        guard SWModule_setVerseKeyIndex(self.handle, CLong(ordinal)) == 0,
                              let children = Self.currentVerseKeyChildren(handle: self.handle),
                              children.chapter > 0,
                              children.verse > 0,
                              Int(SWModule_getVerseKeyIndex(self.handle)) == ordinal else {
                            return nil
                        }
                        return VerseKeyReference(
                            osisBookId: children.osisBookName,
                            chapter: children.chapter,
                            verse: children.verse,
                            ordinal: ordinal
                        )
                    }

                    guard let startReference = referenceAtOrdinal(startOrdinal) else {
                        captureResult = .failure(.nonAddressableEndpoint(startOrdinal))
                        return try Self.finishSourceInspection(
                            captureResult,
                            restoring: cursorSnapshot,
                            handle: handle
                        )
                    }
                    guard let endReference = referenceAtOrdinal(endOrdinal) else {
                        captureResult = .failure(.nonAddressableEndpoint(endOrdinal))
                        return try Self.finishSourceInspection(
                            captureResult,
                            restoring: cursorSnapshot,
                            handle: handle
                        )
                    }

                    let count = distance + 1
                    var entries: [SwordVerseSourceEntry] = []
                    entries.reserveCapacity(count)
                    for offset in 0..<count {
                        let ordinal = startOrdinal + offset
                        guard let reference = referenceAtOrdinal(ordinal) else { continue }
                        let osis = SwordSourceFormatOSISConverter.fragment(handle: handle)
                        let canonical = SWModule_getStripText(handle).map(String.init(cString:))
                        entries.append(SwordVerseSourceEntry(
                            reference: reference,
                            osisFragment: osis.isEmpty ? nil : osis,
                            canonicalText: canonical.flatMap { $0.isEmpty ? nil : $0 }
                        ))
                    }

                    let canonicalText = SwordBibleCanonicalTextProjection.project(entries)
                    let sourceOSISRange = startReference.osisRef == endReference.osisRef
                        ? startReference.osisRef
                        : "\(startReference.osisRef)-\(endReference.osisRef)"
                    captureResult = .success(SwordVerseSourceRange(
                        entries: entries,
                        sourceOrdinalStart: startOrdinal,
                        sourceOrdinalEnd: endOrdinal,
                        sourceOSISRange: sourceOSISRange,
                        canonicalText: canonicalText
                    ))
                }
            }

            return try Self.finishSourceInspection(
                captureResult,
                restoring: cursorSnapshot,
                handle: handle
            )
        }
    }

    /** Restores captured key and VerseKey index, publishing no result unless both are exact. */
    private static func finishSourceInspection(
        _ result: Result<SwordVerseSourceRange, SwordVerseSourceInspectionError>,
        restoring snapshot: SwordModuleCursorSnapshot,
        handle: UnsafeMutableRawPointer
    ) throws -> SwordVerseSourceRange {
        SWModule_setKeyText(handle, snapshot.keyText)
        if let verseIndex = snapshot.verseIndex {
            _ = SWModule_setVerseKeyIndex(handle, CLong(verseIndex))
        }
        let restoredIndex: Int?
        if snapshot.verseIndex != nil {
            let restoredIndexValue = SWModule_getVerseKeyIndex(handle)
            restoredIndex = restoredIndexValue >= 0 ? Int(restoredIndexValue) : nil
        } else {
            restoredIndex = nil
        }
        guard snapshot.matches(
            restoredKeyText: String(cString: SWModule_getKeyText(handle)),
            restoredVerseIndex: restoredIndex
        ) else {
            throw SwordVerseSourceInspectionError.cursorRestorationFailed
        }
        return try result.get()
    }

    /**
     Captures the complete cursor identity needed by bounded key enumeration and native search.

     - Parameters:
       - handle: Live SWORD module handle already protected by `SwordRuntime`.
       - includesVerseIndex: Whether this module category is backed by a VerseKey cursor.
     - Returns: Copied key text plus the VerseKey ordinal when the module exposes one.
     - Side effects: Reads native cursor state without moving it.
     - Failure modes: Non-VerseKey modules report `nil` ordinal and remain key-text addressed.
     */
    private static func currentCursorSnapshot(
        handle: UnsafeMutableRawPointer,
        includesVerseIndex: Bool
    ) -> SwordModuleCursorSnapshot {
        let indexValue = SWModule_getVerseKeyIndex(handle)
        return SwordModuleCursorSnapshot(
            keyText: String(cString: SWModule_getKeyText(handle)),
            verseIndex: includesVerseIndex && indexValue >= 0 ? Int(indexValue) : nil
        )
    }

    /**
     Restores one previously captured key/ordinal pair after bounded native traversal.

     - Parameters:
       - snapshot: Key text and optional VerseKey ordinal captured before traversal.
       - clonedKey: Single-use native key clone preserving unpositioned and subclass-specific state.
       - handle: Live SWORD module handle already protected by `SwordRuntime`.
     - Returns: `true` only when the restored key text and optional VerseKey ordinal exactly match
       the captured cursor.
     - Side effects: Consumes and destroys `clonedKey`, restores its complete native key state, then
       validates the visible key text and optional VerseKey ordinal.
     - Failure modes: Returns `false` when native clone restoration fails or the post-restore
       key/index identity differs; callers fail closed instead of publishing results.
     */
    @discardableResult
    private static func restoreCursor(
        _ snapshot: SwordModuleCursorSnapshot,
        clonedKey: UnsafeMutableRawPointer,
        handle: UnsafeMutableRawPointer
    ) -> Bool {
        guard SWModule_restoreClonedKey(handle, clonedKey) == 0 else {
            return false
        }
        guard snapshot.verseIndex != nil else {
            return true
        }
        let restoredIndex: Int?
        let restoredIndexValue = SWModule_getVerseKeyIndex(handle)
        restoredIndex = restoredIndexValue >= 0 ? Int(restoredIndexValue) : nil
        return snapshot.matches(
            restoredKeyText: String(cString: SWModule_getKeyText(handle)),
            restoredVerseIndex: restoredIndex
        )
    }

    private static func currentVerseKeyChildren(handle: UnsafeMutableRawPointer) -> VerseKeyChildren? {
        guard let children = SWModule_getKeyChildren(handle) else { return nil }

        var parts: [String] = []
        var index = 0
        while index < 11, let ptr = children[index] {
            parts.append(String(cString: ptr))
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
        let fallbackOsisBookName = osisRef.components(separatedBy: ".").first ?? osisRef
        let shortText = parts.count > 8 && !parts[8].isEmpty ? parts[8] : osisRef
        let bookAbbreviation = parts.count > 9 && !parts[9].isEmpty ? parts[9] : fallbackOsisBookName
        let osisBookName = parts.count > 10 && !parts[10].isEmpty ? parts[10] : fallbackOsisBookName

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
            shortText: shortText,
            bookAbbreviation: bookAbbreviation,
            osisBookName: osisBookName
        )
    }

    /// Positions an exact verse key and rejects SWORD normalization to neighboring references.
    private func exactVerseKeyChildrenLocked(osisBookId: String, chapter: Int, verse: Int) -> VerseKeyChildren? {
        SWModule_setKeyText(handle, "=\(osisBookId).\(chapter).\(verse)")
        guard let children = Self.currentVerseKeyChildren(handle: handle),
              children.osisBookName == osisBookId,
              children.chapter == chapter,
              children.verse == verse,
              children.chapter <= children.chapterMax,
              children.verse <= children.verseMax else {
            return nil
        }
        return children
    }

    /**
     Parses a Bible key string through SWORD's VerseKey parser and returns normalized OSIS keys.

     Android routes Bible references through JSword `PassageKeyFactory`; the closest available
     iOS boundary in the current flat bridge is SWORD's `SWModule_parseKeyList`, which expands
     ranges and lists against the active module's versification instead of using string splitting.
     The result is copied immediately because the C array belongs to the module handle and is
     invalidated by later parse calls.

     - Parameter keyText: OSIS or human-readable key text such as `Gen.1.1-Gen.1.3`.
     - Returns: Normalized OSIS references, one per parsed verse/range item. Returns an empty
       array when SWORD cannot parse the text for a VerseKey module.
     - Side effects: Uses SWORD's parser inside the module serialization queue. The method restores
       the module cursor after parsing so callers can use it in reader link handling without
       desynchronizing later raw-entry reads.
     */
    public func parseKeyList(_ keyText: String) -> [String] {
        SwordRuntime.sync {
            let previousKey = String(cString: SWModule_getKeyText(handle))
            defer { SWModule_setKeyText(handle, previousKey) }

            guard let values = SWModule_parseKeyList(handle, keyText) else { return [] }
            return Self.copyCStringArray(values)
        }
    }

    /**
     Returns the active module versification's last verse number for a chapter.

     Android's passage chooser uses JSword `Versification.getLastVerse(book, chapterNo)`. SWORD
     exposes the equivalent through the current `VerseKey` children after resolving any verse in
     the target chapter. The method rejects SWORD normalization onto a neighboring key by checking
     the resolved OSIS book and chapter before returning `verseMax`.

     - Parameters:
       - osisBookId: OSIS book identifier such as `Gen`, `Ruth`, or `1Cor`.
       - chapter: One-based chapter number.
     - Returns: The last valid verse number for that chapter, or `nil` if the reference cannot be
       resolved exactly by the module's versification.
     - Side effects: Temporarily moves the module cursor and restores the previous key before
       returning.
     */
    public func verseCount(osisBookId: String, chapter: Int) -> Int? {
        guard chapter > 0, !osisBookId.isEmpty else { return nil }

        return SwordRuntime.sync {
            let previousKey = String(cString: SWModule_getKeyText(handle))
            defer { SWModule_setKeyText(handle, previousKey) }

            SWModule_setKeyText(handle, "=\(osisBookId).\(chapter).1")
            guard let children = Self.currentVerseKeyChildren(handle: handle),
                  children.osisBookName == osisBookId,
                  children.chapter == chapter,
                  children.chapter <= children.chapterMax,
                  children.verseMax > 0 else {
                return nil
            }
            return children.verseMax
        }
    }

    /**
     Copies a NULL-terminated C string array returned by the SWORD flat API.

     - Parameter values: Pointer to a NULL-terminated array owned by SWORD.
     - Returns: Swift strings copied before a later SWORD call can invalidate the backing storage.
     */
    private static func copyCStringArray(_ values: UnsafePointer<UnsafePointer<CChar>?>) -> [String] {
        var result: [String] = []
        var index = 0
        while let value = values[index] {
            result.append(String(cString: value))
            index += 1
        }
        return result
    }

    /**
     Get entry attributes produced by the current render pipeline.

     SWORD populates these attributes after rendering a verse. They expose
     structural metadata like preverse and interverse headings in a much more
     stable form than `renderHeader()`, which is only CSS.
     */
    public func entryAttributes(level1: String? = nil,
                                level2: String? = nil,
                                level3: String? = nil,
                                filtered: Bool = false) -> [String] {
        SwordRuntime.sync {
            func withOptionalCString<T>(_ value: String?, _ body: (UnsafePointer<CChar>?) -> T) -> T {
                guard let value else { return body(nil) }
                return value.withCString(body)
            }

            return withOptionalCString(level1) { level1Ptr in
                withOptionalCString(level2) { level2Ptr in
                    withOptionalCString(level3) { level3Ptr in
                        guard let values = SWModule_getEntryAttribute(
                            handle,
                            level1Ptr,
                            level2Ptr,
                            level3Ptr,
                            filtered ? 1 : 0
                        ) else {
                            return []
                        }

                        return Self.copyCStringArray(values)
                    }
                }
            }
        }
    }

    /**
     Navigate to the next entry/verse.
     - Returns: `true` if navigation succeeded (not at end).
     */
    @discardableResult
    public func next() -> Bool {
        SwordRuntime.sync {
            SWModule_next(handle) == 0
        }
    }

    /**
     Navigate to the previous entry/verse.
     - Returns: `true` if navigation succeeded (not at beginning).
     */
    @discardableResult
    public func previous() -> Bool {
        SwordRuntime.sync {
            SWModule_previous(handle) == 0
        }
    }

    /// Navigate to the beginning of the module.
    public func begin() {
        SwordRuntime.sync {
            SWModule_begin(handle)
        }
    }

    /// Check if the current position is at the end.
    public var isAtEnd: Bool {
        SwordRuntime.sync {
            SWModule_isEnd(handle) != 0
        }
    }

    // MARK: - Text Retrieval

    /**
     Atomically set key, read back actual key, and render text in one `SwordRuntime.sync` block.
     This prevents interleaving with other SWORD operations between setKey/currentKey/renderText.
     Returns (actualKey, renderedText).
     */
    public func setKeyAndRender(_ keyText: String) -> (actualKey: String, text: String) {
        SwordRuntime.sync {
            SWModule_setKeyText(handle, keyText)
            let actualKey = String(cString: SWModule_getKeyText(handle))
            let text = String(cString: SWModule_getRenderText(handle))
            return (actualKey, text)
        }
    }

    /**
     Atomically set key, then capture the resolved key and entry text forms.

     Dictionary and lexical-search lookups need these values together because SWORD can reposition
     to a nearby key when an exact match is missing, and some modules expose canonical metadata only
     through raw entry markup. Callers that need only raw OSIS can skip rendered/stripped text to
     avoid paying that cost for every verse during module-wide scans.
     */
    public func setKeyAndInspect(
        _ keyText: String,
        includeRenderedText: Bool = true,
        includeStrippedText: Bool = true
    ) -> (actualKey: String, rawEntry: String, renderedText: String, strippedText: String) {
        SwordRuntime.sync {
            SWModule_setKeyText(handle, keyText)
            let actualKey = String(cString: SWModule_getKeyText(handle))
            let rawEntry = String(cString: SWModule_getRawEntry(handle))
            let renderedText = includeRenderedText
                ? String(cString: SWModule_getRenderText(handle))
                : ""
            let strippedText = includeStrippedText
                ? String(cString: SWModule_getStripText(handle))
                : ""
            return (actualKey, rawEntry, renderedText, strippedText)
        }
    }

    /// Get rendered text (with markup/HTML) at the current position.
    public func renderText() -> String {
        SwordRuntime.sync {
            String(cString: SWModule_getRenderText(handle))
        }
    }

    /// Get raw entry text at the current position (no markup processing).
    public func rawEntry() -> String {
        SwordRuntime.sync {
            String(cString: SWModule_getRawEntry(handle))
        }
    }

    /// Get plain/strip text at the current position (no markup at all).
    public func stripText() -> String {
        SwordRuntime.sync {
            String(cString: SWModule_getStripText(handle))
        }
    }

    /// Get rendered header text (chapter/book introductions).
    public func renderHeader() -> String {
        SwordRuntime.sync {
            String(cString: SWModule_getRenderHeader(handle))
        }
    }

    // MARK: - Configuration

    /**
     Get a module configuration entry value.
     - Parameter key: The config key (e.g., "About", "LCSH", "DistributionLicense").
     - Returns: The value, or nil if not found.
     */
    public func configEntry(_ key: String) -> String? {
        SwordRuntime.sync {
            guard let cStr = SWModule_getConfigEntry(handle, key) else { return nil }
            return String(cString: cStr)
        }
    }

    /**
     Set the cipher key for encrypted modules.
     - Parameter key: The decryption key.
     */
    public func setCipherKey(_ key: String) {
        SwordRuntime.sync {
            SWModule_setCipherKey(handle, key)
        }
    }

    // MARK: - Versification / Book List

    /**
     Get the list of all books in this Bible module's versification.

     Mirrors Android's `DocumentBibleBooks`/JSword contract as closely as the current
     CLibSword wrapper allows: discover candidate books from real SWORD key positions, then
     include only books whose first or second verse resolves exactly and has raw content.
     This intentionally avoids synthetic "high verse" jumps such as `Gen 50:200`;
     compressed zText modules can normalize those fake keys past intervening books, which
     hides valid restored Android module content from the reader's book picker.

     - Returns: Ordered array of `BookInfo` for each book in the module's canon.
       Returns empty array for non-Bible modules or if the module has no verse key.
     - Side effects: Temporarily moves the module cursor while holding the module queue,
       then restores the previously selected key before returning.
     - Complexity: O(n) over the module's key entries. The reader calls this only when
       refreshing module metadata, and correctness is more important than key-jump speed.
     */
    public func getBookList() -> [BookInfo] {
        guard info.category == .bible || info.category == .commentary else { return [] }
        return SwordRuntime.sync {
            let savedKey = String(cString: SWModule_getKeyText(handle))
            defer { SWModule_setKeyText(handle, savedKey) }

            SWModule_begin(handle)
            guard SWModule_popError(handle) == 0 else { return [] }

            var candidateBooks: [BookInfo] = []
            var seenBookIds = Set<String>()
            var previousKey: String?
            let isProbablyIBTSynodalDocument = Self.isProbablyIBTSynodalDocument(handle: handle)

            while true {
                let key = String(cString: SWModule_getKeyText(handle))
                guard key != previousKey else { break }
                previousKey = key

                if let children = Self.currentVerseKeyChildren(handle: handle),
                   children.testament > 0,
                   !children.osisBookName.isEmpty,
                   seenBookIds.insert(children.osisBookName).inserted {
                    candidateBooks.append(BookInfo(
                        name: children.bookName,
                        osisId: children.osisBookName,
                        abbreviation: children.bookAbbreviation,
                        chapterCount: children.chapterMax,
                        testament: children.testament
                    ))
                }

                if SWModule_next(handle) != 0 { break }
            }

            return candidateBooks.filter { book in
                Self.moduleContainsAndroidProbeVerse(
                    handle: handle,
                    book: book,
                    chapter: 1,
                    verse: 1,
                    isProbablyIBTSynodalDocument: isProbablyIBTSynodalDocument
                ) || Self.moduleContainsAndroidProbeVerse(
                    handle: handle,
                    book: book,
                    chapter: 1,
                    verse: 2,
                    isProbablyIBTSynodalDocument: isProbablyIBTSynodalDocument
                )
            }
        }
    }

    /**
     Checks one Android-compatible book-list probe verse.

     Android's `DocumentBibleBooks.isVerseInBook()` includes a book only when JSword's backend
     reports raw content for either 1:1 or 1:2. This helper uses exact OSIS keys and verifies
     that SWORD did not normalize the request onto a neighboring key before checking raw content.
     It runs inside `getBookList()`'s serialized queue block and intentionally leaves cursor
     restoration to the outer caller.

     - Parameters:
       - handle: SWORD module handle already owned by the caller's queue.
       - book: Candidate book metadata collected from real SWORD key traversal.
       - chapter: Probe chapter number, normally `1`.
       - verse: Probe verse number, normally `1` or `2`.
       - isProbablyIBTSynodalDocument: Whether the module matches Android's known IBT Synodal
         empty-stub pattern for deuterocanonical books.
     - Returns: `true` when the requested exact verse belongs to the candidate book and has
       non-empty raw content that Android would treat as real content.
     - Side effects: Moves the module cursor to the probe key.
     */
    private static func moduleContainsAndroidProbeVerse(
        handle: UnsafeMutableRawPointer,
        book: BookInfo,
        chapter: Int,
        verse: Int,
        isProbablyIBTSynodalDocument: Bool
    ) -> Bool {
        guard let rawEntryLength = rawEntryLengthForExactVerse(
            handle: handle,
            osisBookId: book.osisId,
            chapter: chapter,
            verse: verse
        ), rawEntryLength > 0 else {
            return false
        }

        if isProbablyIBTSynodalDocument,
           isProbablyIBTEmptyVerseStub(rawEntryLength: rawEntryLength, isShortBook: book.chapterCount <= 1) {
            return false
        }

        return true
    }

    /**
     Returns the raw entry length for one exact OSIS verse key.

     SWORD may normalize invalid references to nearby verses. Android's JSword path checks a
     concrete `Verse`, so this helper rejects normalized probes by comparing structured
     `VerseKey` children after setting the key.

     - Parameters:
       - handle: SWORD module handle already owned by the caller's queue.
       - osisBookId: OSIS book identifier such as `Gen` or `1Cor`.
       - chapter: Chapter to inspect.
       - verse: Verse to inspect.
     - Returns: Raw entry character count when SWORD resolves exactly to the requested verse;
       otherwise `nil`.
     - Side effects: Moves the module cursor to the requested key.
     */
    private static func rawEntryLengthForExactVerse(
        handle: UnsafeMutableRawPointer,
        osisBookId: String,
        chapter: Int,
        verse: Int
    ) -> Int? {
        SWModule_setKeyText(handle, "=\(osisBookId).\(chapter).\(verse)")
        guard let children = currentVerseKeyChildren(handle: handle),
              children.osisBookName == osisBookId,
              children.chapter == chapter,
              children.verse == verse else {
            return nil
        }
        return String(cString: SWModule_getRawEntry(handle)).count
    }

    /**
     Detects Android's known IBT Synodal empty deuterocanonical-verse stub condition.

     Android checks for Synodal modules where `Tob 1:1` contains generated empty markup rather
     than real verse content, then excludes similarly-shaped stubs from the book list. This keeps
     iOS book visibility aligned for the same module family without applying the heuristic to
     unrelated versifications.

     - Parameter handle: SWORD module handle already owned by the caller's queue.
     - Returns: `true` when the module declares `Versification=Synodal` and `Tob 1:1` has the
       raw-length signature Android treats as an IBT empty stub.
     - Side effects: Moves the module cursor to `Tob 1:1`; `getBookList()` restores the original
       cursor before returning.
     */
    private static func isProbablyIBTSynodalDocument(handle: UnsafeMutableRawPointer) -> Bool {
        let versificationPointer = SWModule_getConfigEntry(handle, "Versification")
        let versificationName = versificationPointer.map { String(cString: $0) } ?? "KJV"
        guard versificationName == "Synodal",
              let rawEntryLength = rawEntryLengthForExactVerse(
                handle: handle,
                osisBookId: "Tob",
                chapter: 1,
                verse: 1
              ) else {
            return false
        }
        return isProbablyIBTEmptyVerseStub(rawEntryLength: rawEntryLength, isShortBook: false)
    }

    /**
     Matches Android's raw-length heuristic for IBT Synodal empty verse stubs.

     Android identifies generated empty markup by length range because the affected modules return
     non-empty raw XML for books that are not actually present. The constants below are the Swift
     equivalents of `DocumentBibleBooks` in Android.

     - Parameters:
       - rawEntryLength: Length of the raw SWORD entry.
       - isShortBook: Whether the probed book has a single chapter.
     - Returns: `true` when the raw entry length falls inside Android's empty-stub range.
     */
    private static func isProbablyIBTEmptyVerseStub(rawEntryLength: Int, isShortBook: Bool) -> Bool {
        if isShortBook {
            return ibtShortBookEmptyVerseStubRange.contains(rawEntryLength)
        }
        return ibtEmptyVerseStubRange.contains(rawEntryLength)
    }

    private static let ibtEmptyVerseStubRange: ClosedRange<Int> = {
        let lowerBound = "<chapter eID=\"gen4\" osisID=\"Gen.1\"/>".count
        let upperBound = "<chapter eID=\"gen1146\" osisID=\"1Macc.1\"/>".count
        return lowerBound...upperBound
    }()

    private static let ibtShortBookEmptyVerseStubRange: ClosedRange<Int> = {
        let lowerBound = "<chapter eID=\"gen955\" osisID=\"Obad.1\"/> <div eID=\"gen954\" osisID=\"Obad\" type=\"book\"/> <div eID=\"gen953\" type=\"x-Synodal-empty\"/>".count
        let upperBound = "<chapter eID=\"gen1136\" osisID=\"EpJer.1\"/> <div eID=\"gen1135\" osisID=\"EpJer\" type=\"book\"/> <div eID=\"gen1134\" type=\"x-Synodal-non-canonical\"/>".count
        return lowerBound...upperBound
    }()

    // MARK: - Key Browsing

    /**
     Loads every entry key for dictionary, general-book, and map browsing.

     The method preserves source order and duplicate/empty keys because Android's chooser filtering
     owns those presentation decisions. SWORD error code `1` is the normal out-of-bounds sentinel for
     an empty module or the end of a successful iteration; any other code is a backend failure.

     - Returns: Exact module keys in source order, sharing the successful module-lifetime snapshot.
     - Side effects: The first successful read temporarily moves the module cursor while holding
       `SwordRuntime`, restores the caller's previous key and VerseKey ordinal, and caches the
       immutable result. Cached reads do not touch the native cursor.
     - Throws: `SwordModuleKeyAccessError.keyListReadFailed` when SWORD reports a non-terminal
       backend error, or `cursorRestorationFailed` when the exact original cursor cannot be proven.
       Failures are not cached; callers must keep them distinct from a successful empty array and
       may retry.
     */
    public func loadAllKeys() throws -> [String] {
        try SwordRuntime.sync {
            if let cachedAllKeys {
                return cachedAllKeys
            }

            let cursorSnapshot = Self.currentCursorSnapshot(
                handle: handle,
                includesVerseIndex: info.category == .bible || info.category == .commentary
            )
            guard let clonedCursor = SWModule_cloneCurrentKey(handle) else {
                throw SwordModuleKeyAccessError.cursorRestorationFailed(moduleName: info.name)
            }

            SWModule_begin(handle)
            let startError = Int(SWModule_popError(handle))
            if startError == Self.endOfKeyListErrorCode {
                guard Self.restoreCursor(
                    cursorSnapshot,
                    clonedKey: clonedCursor,
                    handle: handle
                ) else {
                    throw SwordModuleKeyAccessError.cursorRestorationFailed(moduleName: info.name)
                }
                cachedAllKeys = []
                return []
            }
            guard startError == 0 else {
                guard Self.restoreCursor(
                    cursorSnapshot,
                    clonedKey: clonedCursor,
                    handle: handle
                ) else {
                    throw SwordModuleKeyAccessError.cursorRestorationFailed(moduleName: info.name)
                }
                throw SwordModuleKeyAccessError.keyListReadFailed(
                    moduleName: info.name,
                    errorCode: startError
                )
            }

            var keys: [String] = []
            while true {
                let key = String(cString: SWModule_getKeyText(handle))
                keys.append(key)
                let nextError = Int(SWModule_next(handle))
                if nextError == Self.endOfKeyListErrorCode {
                    break
                }
                guard nextError == 0 else {
                    guard Self.restoreCursor(
                        cursorSnapshot,
                        clonedKey: clonedCursor,
                        handle: handle
                    ) else {
                        throw SwordModuleKeyAccessError.cursorRestorationFailed(moduleName: info.name)
                    }
                    throw SwordModuleKeyAccessError.keyListReadFailed(
                        moduleName: info.name,
                        errorCode: nextError
                    )
                }
            }
            guard Self.restoreCursor(
                cursorSnapshot,
                clonedKey: clonedCursor,
                handle: handle
            ) else {
                throw SwordModuleKeyAccessError.cursorRestorationFailed(moduleName: info.name)
            }
            cachedAllKeys = keys
            return keys
        }
    }

    /**
     Loads physical RawLD-family source-index slots without libsword normalization.

     JSword's `RawLDBackend.search` derives Strong's padding from the first binary-search index
     entry it probes. libsword's generic cursor can case-fold, pad, or collapse those stored key
     spellings before `loadAllKeys()` observes them, which changes that first-probe pattern for
     mixed-width dictionaries. This boundary reads the valid fixed-width index records directly and
     extracts each record's key header in physical source order.

     - Returns: Physical slots in index order, including duplicates and zero-size placeholders, for
       `RawLD`, `RawLD4`, and `zLD`; `nil` for other drivers.
     - Side effects: Reads the installed module's `.conf`, `.idx`, and `.dat` files once and caches a
       successful immutable snapshot under `SwordRuntime` serialization.
     - Throws: `SwordModuleKeyAccessError.rawDictionaryIndexReadFailed` when the module path,
       descriptor, contained source paths, fixed-width index, referenced record bounds, or key text
       encoding is invalid. Zero-size slots remain explicit `nil` keys for the JSword search layer.
     */
    public func loadRawDictionaryIndexSlots() throws -> [SwordRawDictionaryIndexSlot]? {
        try SwordRuntime.sync {
            if let cachedRawDictionaryIndexSlots {
                return cachedRawDictionaryIndexSlots
            }
            guard let moduleRootPath,
                  let config = SwordModuleConfig.read(name: info.name, modulePath: moduleRootPath) else {
                throw SwordModuleKeyAccessError.rawDictionaryIndexReadFailed(moduleName: info.name)
            }

            let driver = config.modDrv.lowercased()
            let indexRecordSize: Int
            let lengthByteCount: Int
            switch driver {
            case "rawld":
                indexRecordSize = 6
                lengthByteCount = 2
            case "rawld4", "zld":
                indexRecordSize = 8
                lengthByteCount = 4
            default:
                return nil
            }
            guard !config.dataPath.isEmpty else {
                throw SwordModuleKeyAccessError.rawDictionaryIndexReadFailed(moduleName: info.name)
            }

            let moduleRootURL = URL(fileURLWithPath: moduleRootPath, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            let dataPrefix = moduleRootURL
                .appendingPathComponent(config.dataPath, isDirectory: false)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            let containedPrefix = moduleRootURL.path.hasSuffix("/")
                ? moduleRootURL.path
                : moduleRootURL.path + "/"
            let indexURL = dataPrefix.appendingPathExtension("idx")
                .standardizedFileURL
                .resolvingSymlinksInPath()
            let entryURL = dataPrefix.appendingPathExtension("dat")
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard dataPrefix.path.hasPrefix(containedPrefix),
                  indexURL.path.hasPrefix(containedPrefix),
                  entryURL.path.hasPrefix(containedPrefix) else {
                throw SwordModuleKeyAccessError.rawDictionaryIndexReadFailed(moduleName: info.name)
            }
            guard let indexData = try? Data(contentsOf: indexURL),
                  let entryData = try? Data(contentsOf: entryURL) else {
                throw SwordModuleKeyAccessError.rawDictionaryIndexReadFailed(moduleName: info.name)
            }

            let keyEncoding = try Self.rawDictionaryKeyEncoding(
                config: config,
                moduleName: info.name
            )
            let slotCount = indexData.count / indexRecordSize
            guard slotCount > 0 else {
                throw SwordModuleKeyAccessError.rawDictionaryIndexReadFailed(moduleName: info.name)
            }
            var slots: [SwordRawDictionaryIndexSlot] = []
            slots.reserveCapacity(slotCount)
            for physicalIndex in 0..<slotCount {
                let recordStart = physicalIndex * indexRecordSize
                let offset = Self.littleEndianInteger(
                    in: indexData,
                    range: recordStart..<(recordStart + 4)
                )
                let length = Self.littleEndianInteger(
                    in: indexData,
                    range: (recordStart + 4)..<(recordStart + 4 + lengthByteCount)
                )
                if length == 0 {
                    slots.append(SwordRawDictionaryIndexSlot(
                        index: physicalIndex,
                        key: nil,
                        size: 0,
                        dataOffset: nil
                    ))
                    continue
                }
                guard offset <= entryData.count,
                      length <= entryData.count - offset else {
                    throw SwordModuleKeyAccessError.rawDictionaryIndexReadFailed(moduleName: info.name)
                }

                let recordRange = offset..<(offset + length)
                var keyEnd = entryData[recordRange].firstIndex(of: 0x0A) ?? offset
                if keyEnd > offset, entryData[keyEnd - 1] == 0x0D {
                    keyEnd -= 1
                }
                if keyEnd > offset, entryData[keyEnd - 1] == 0x5C {
                    keyEnd -= 1
                }
                let key = try Self.decodeRawDictionaryKey(
                    entryData.subdata(in: offset..<keyEnd),
                    encoding: keyEncoding,
                    moduleName: info.name
                )
                slots.append(SwordRawDictionaryIndexSlot(
                    index: physicalIndex,
                    key: key,
                    size: length,
                    dataOffset: driver == "zld" ? nil : offset
                ))
            }
            cachedRawDictionaryEntryURL = entryURL
            cachedRawDictionaryIndexSlots = slots
            return slots
        }
    }

    /**
     Reads the exact selected RawLD/RawLD4 record without retaining every dictionary body in memory.

     - Parameter slot: Validated positive-size physical slot returned by this module's cached index
       snapshot.
     - Returns: Exact record bytes, including the DataEntry key header and delimiter.
     - Side effects: Memory-maps the already contained `.dat` file and copies only the selected
       record under `SwordRuntime` serialization.
     - Throws: `rawDictionaryIndexReadFailed` when the slot is synthetic/zLD/zero-size, the cached
       file is unavailable, or its bounds changed after index capture.
     */
    func rawDictionaryRecord(for slot: SwordRawDictionaryIndexSlot) throws -> Data {
        try SwordRuntime.sync {
            guard slot.size > 0,
                  let offset = slot.dataOffset,
                  let entryURL = cachedRawDictionaryEntryURL,
                  let entryData = try? Data(contentsOf: entryURL, options: .mappedIfSafe),
                  offset <= entryData.count,
                  slot.size <= entryData.count - offset else {
                throw SwordModuleKeyAccessError.rawDictionaryIndexReadFailed(moduleName: info.name)
            }
            return entryData.subdata(in: offset..<(offset + slot.size))
        }
    }

    /**
     Identifies JSword's configured dictionary-key charset.

     - Parameters:
       - config: Parsed module config containing the optional `Encoding` entry.
       - moduleName: Initials included in typed read failures.
     - Returns: UTF-8 for the exact `UTF-8` config spelling, or Windows-1252 for a missing or exact
       `Latin-1` value.
     - Side effects: None.
     - Throws: `rawDictionaryIndexReadFailed` for any encoding outside JSword's pinned two-value
       map.
     */
    private static func rawDictionaryKeyEncoding(
        config: SwordModuleConfig,
        moduleName: String
    ) throws -> RawDictionaryKeyEncoding {
        let configured = config.values["Encoding"]?.first ?? "Latin-1"
        switch configured {
        case "UTF-8":
            return .utf8
        case "Latin-1":
            return .windowsCP1252
        default:
            throw SwordModuleKeyAccessError.rawDictionaryIndexReadFailed(moduleName: moduleName)
        }
    }

    /**
     Decodes one RawLD DataEntry key through pinned JSword `SwordUtil.decode` semantics.

     JSword cleans disallowed C0 controls and undefined bytes only for its Windows-1252 mapping.
     UTF-8 bypasses that cleanup and uses Java's replacement decoder directly, preserving valid
     controls while replacing malformed byte sequences. Both paths keep a bad byte from turning
     into a whole-module read failure.

     - Parameters:
       - data: Exact key bytes before DataEntry's LF delimiter and optional CR/backslash removal.
       - encoding: Pinned JSword charset selected from module configuration.
       - moduleName: Initials included in the typed failure if Windows-1252 cannot be materialized.
     - Returns: JSword-compatible key text, including U+FFFD for malformed UTF-8 sequences.
     - Side effects: Copies the bounded key bytes and sanitizes only Windows-1252 input.
     - Throws: `rawDictionaryIndexReadFailed` only if Foundation cannot decode the sanitized,
       fully-defined Windows-1252 byte sequence; malformed UTF-8 is replacement-decoded.
     */
    private static func decodeRawDictionaryKey(
        _ data: Data,
        encoding: RawDictionaryKeyEncoding,
        moduleName: String
    ) throws -> String {
        switch encoding {
        case .utf8:
            return String(decoding: data, as: UTF8.self)
        case .windowsCP1252:
            let undefinedWindows1252Bytes: Set<UInt8> = [0x81, 0x8D, 0x8F, 0x90, 0x9D]
            let cleaned = data.map { byte -> UInt8 in
                let isDisallowedControl = byte < 0x20
                    && byte != 0x09
                    && byte != 0x0A
                    && byte != 0x0D
                return isDisallowedControl || undefinedWindows1252Bytes.contains(byte)
                    ? 0x20
                    : byte
            }
            guard let decoded = String(
                data: Data(cleaned),
                encoding: .windowsCP1252
            ) else {
                throw SwordModuleKeyAccessError.rawDictionaryIndexReadFailed(
                    moduleName: moduleName
                )
            }
            return decoded
        }
    }

    /**
     Pinned JSword dictionary-key charset after exact configuration lookup.

     Values are produced only by `rawDictionaryKeyEncoding`, which applies JSword's exact config
     spelling and missing-value default before physical index bytes are decoded.

     - Side effects: None.
     - Failure modes: Unsupported config values never create an instance; the selector throws a
       typed module read failure instead.
     */
    private enum RawDictionaryKeyEncoding {
        /// Java UTF-8 decoder, including replacement of malformed byte sequences.
        case utf8

        /// JSword's `Latin-1` alias, which intentionally maps to Windows-1252.
        case windowsCP1252
    }

    /**
     Decodes one unsigned little-endian integer from a validated data slice.

     - Parameters:
       - data: Fixed-width RawLD index bytes.
       - range: Two- or four-byte bounds contained by `data`.
     - Returns: Host-width nonnegative integer assembled without alignment assumptions.
     - Side effects: None.
     - Failure modes: Callers validate the range and supported width before invoking this helper.
     */
    private static func littleEndianInteger(in data: Data, range: Range<Int>) -> Int {
        var value: UInt64 = 0
        for (shift, index) in range.enumerated() {
            value |= UInt64(data[index]) << UInt64(shift * 8)
        }
        return Int(value)
    }

    /**
     Collects module keys for legacy non-interactive scans that cannot present read failures.

     Interactive dictionary/general-book/map surfaces must call `loadAllKeys()` so backend errors do
     not masquerade as empty modules. This compatibility method remains for existing search and speech
     pipelines whose public contracts currently accept only an array.

     - Returns: Exact keys, or an empty array when key enumeration fails.
     - Side effects: Delegates to `loadAllKeys()`, including temporary cursor movement/restoration.
     - Failure modes: Intentionally collapses the typed error for compatibility; do not use it for UI.
     */
    public func allKeys() -> [String] {
        (try? loadAllKeys()) ?? []
    }

    /**
     Tests whether a generic SWORD module contains one exact key without accepting nearest-key snaps.

     - Parameter keyText: Previously selected dictionary/general-book/map key to validate.
     - Returns: `true` only when loading the entry leaves SWORD positioned on the identical key;
       empty keys and ordinary out-of-bounds misses return `false`.
     - Side effects: Temporarily moves the module cursor and reads the raw entry to force RawLD and
       TreeKey backends to finalize key normalization, then restores the previous key.
     - Throws: `SwordModuleKeyAccessError.exactKeyReadFailed` for non-terminal backend errors.
     */
    public func containsExactKey(_ keyText: String) throws -> Bool {
        guard !keyText.isEmpty else { return false }

        return try SwordRuntime.sync {
            let savedKey = String(cString: SWModule_getKeyText(handle))
            defer { SWModule_setKeyText(handle, savedKey) }

            SWModule_setKeyText(handle, keyText)
            _ = SWModule_getRawEntry(handle)
            let readError = Int(SWModule_popError(handle))
            if readError == Self.endOfKeyListErrorCode {
                return false
            }
            guard readError == 0 else {
                throw SwordModuleKeyAccessError.exactKeyReadFailed(
                    moduleName: info.name,
                    key: keyText,
                    errorCode: readError
                )
            }
            let resolvedKey = String(cString: SWModule_getKeyText(handle))
            return resolvedKey.utf8.elementsEqual(keyText.utf8)
        }
    }

    /// SWORD's `KEYERR_OUTOFBOUNDS` value, used for an empty module, missing key, or normal EOF.
    private static let endOfKeyListErrorCode = 1

    /**
     Get child keys at the current position (for tree-key modules like general books).
     Returns the NULL-terminated string array from SWORD's getKeyChildren.
     */
    public func keyChildren() -> [String] {
        SwordRuntime.sync {
            guard let children = SWModule_getKeyChildren(handle) else { return [] }
            var result: [String] = []
            var i = 0
            while let ptr = children[i] {
                result.append(String(cString: ptr))
                i += 1
            }
            return result
        }
    }

    // MARK: - Bulk Iteration

    /**
     Iterate through all entries in the module, calling the callback for each.

     The callback receives `(key, plainText, index)` and should return `true` to continue.
     All SWORD operations run in a single `SwordRuntime.sync` block for correctness.
     The module's current key position is saved and restored after iteration.

     - Parameter callback: Called for each entry. Return `false` to stop early.
     */
    public func iterateAllEntries(_ callback: (String, String, Int) -> Bool) {
        SwordRuntime.sync {
            // Save current position
            let savedKey = String(cString: SWModule_getKeyText(handle))

            SWModule_begin(handle)
            guard SWModule_popError(handle) == 0 else {
                SWModule_setKeyText(handle, savedKey)
                return
            }

            var index = 0
            while true {
                let key = String(cString: SWModule_getKeyText(handle))
                let text = String(cString: SWModule_getStripText(handle))
                if !callback(key, text, index) { break }
                index += 1
                if SWModule_next(handle) != 0 { break }
            }

            // Restore position
            SWModule_setKeyText(handle, savedKey)
        }
    }

    /**
     Iterates all entries while capturing each Search source representation from the same cursor.

     Search indexing needs source-neutral OSIS for Android-compatible canonical/preview projection,
     exact raw markup for Strong's attributes, and legacy stripped text for inline Strong's markers.
     Reading them inside one runtime block prevents another SWORD operation from moving the module
     cursor between representations.

     - Parameter callback: Receives `(key, strippedText, rawEntry, osisFragment, index)` for each
       module entry and returns `true` to continue or `false` to stop early.
     - Side effects: Moves the module cursor from the beginning through each entry, then restores
       the cursor that was active before iteration.
     - Failure modes: Stops without invoking the callback when SWORD cannot position at the first
       entry. Native source/filter failures surface as empty representations for that cursor; the
       Search adapter projects and skips that individual empty entry, continues traversal, and lets
       the index service reject only an all-empty generation or roll back a consumer failure.
     - Important: Callback work runs while holding `SwordRuntime`; keep it bounded and do not wait
       on work that also needs SWORD access from another thread. Each entry runs inside its own
       autorelease pool because a full-Bible traversal otherwise accumulates every temporary
       Foundation object until the surrounding dispatch block ends.
     */
    public func iterateAllSearchIndexEntries(
        _ callback: (String, String, String, String, Int) -> Bool
    ) {
        SwordRuntime.sync {
            let savedKey = String(cString: SWModule_getKeyText(handle))
            defer { SWModule_setKeyText(handle, savedKey) }

            SWModule_begin(handle)
            guard SWModule_popError(handle) == 0 else { return }

            var index = 0
            var shouldContinue = true
            while shouldContinue {
                autoreleasepool {
                    let key = String(cString: SWModule_getKeyText(handle))
                    let text = String(cString: SWModule_getStripText(handle))
                    let rawEntry = String(cString: SWModule_getRawEntry(handle))
                    let osisFragment = SwordSourceFormatOSISConverter.fragment(handle: handle)
                    guard callback(key, text, rawEntry, osisFragment, index) else {
                        shouldContinue = false
                        return
                    }
                    index += 1
                    if SWModule_next(handle) != 0 { shouldContinue = false }
                }
            }
        }
    }

    // MARK: - Search

    /**
     Search the module and return only matching keys.

     Strong's candidate-index searches need SWORD's result keys but validate and project each verse
     through the shared structured Search path. Keeping this key-only prevents a caller from
     reintroducing the removed strip-text/fixed-prefix preview API.

     - Parameters:
       - options: Search configuration.
       - limit: Optional maximum number of keys to return.
     - Returns: Matching SWORD keys in result order.
     - Side effects:
       - performs a SWORD search while holding the runtime lock
       - restores the module's current key and VerseKey ordinal after reading search results
     - Failure modes:
       - returns an empty list when SWORD reports no results or the limit is zero
       - throws `SwordModuleKeyAccessError.cursorRestorationFailed` instead of publishing keys when
         the exact caller cursor cannot be proven after the search
     */
    public func searchKeys(_ options: SearchOptions, limit: Int? = nil) throws -> [String] {
        try SwordRuntime.sync {
            let cursorSnapshot = Self.currentCursorSnapshot(
                handle: handle,
                includesVerseIndex: info.category == .bible || info.category == .commentary
            )
            guard let clonedCursor = SWModule_cloneCurrentKey(handle) else {
                throw SwordModuleKeyAccessError.cursorRestorationFailed(moduleName: info.name)
            }

            let flags: Int32 = options.caseInsensitive ? 2 : 0 // REG_ICASE = 2

            _ = SWModule_search(
                handle,
                options.query,
                Int32(options.searchType.rawValue),
                flags,
                options.scope,
                nil
            )

            var keys: [String] = []
            let count = Int(SWModule_searchResultCount(handle))
            let boundedCount = limit.map { min(max($0, 0), count) } ?? count
            if boundedCount > 0 {
                keys.reserveCapacity(boundedCount)
                for index in 0..<boundedCount {
                    keys.append(String(cString: SWModule_getSearchResultKeyText(handle, Int32(index))))
                }
            }
            guard Self.restoreCursor(
                cursorSnapshot,
                clonedKey: clonedCursor,
                handle: handle
            ) else {
                throw SwordModuleKeyAccessError.cursorRestorationFailed(moduleName: info.name)
            }
            return keys
        }
    }

    // MARK: - Feature Detection

    /**
     Detect module features by parsing the .conf file directly from disk.

     SWORD's flat API `getConfigEntry()` only returns the first value for
     multi-value keys like `Feature` and `GlobalOptionFilter`. This causes
     modules where `StrongsNumbers` isn't the first entry (e.g., KJV) to
     be missed. Parsing the .conf file catches all entries.

     Falls back to the C API if the conf file can't be read.
     */
    private static func detectFeatures(
        name: String,
        handle: UnsafeMutableRawPointer,
        modulePath: String?
    ) -> ModuleFeatures {
        var featureValues: [String] = []

        // Try reading .conf file directly (reliable for multi-value keys)
        if let modulePath,
           let config = SwordModuleConfig.read(name: name, modulePath: modulePath) {
            featureValues = (config.values["Feature"] ?? [])
                + (config.values["GlobalOptionFilter"] ?? [])
        } else {
            // Fallback: use C API (only gets first value for multi-value keys)
            var features: ModuleFeatures = []
            if SWModule_hasFeature(handle, "StrongsNumbers") != 0 { features.insert(.strongsNumbers) }
            if SWModule_hasFeature(handle, "GreekDef") != 0 { features.insert(.greekDef) }
            if SWModule_hasFeature(handle, "HebrewDef") != 0 { features.insert(.hebrewDef) }
            if SWModule_hasFeature(handle, "GreekParse") != 0 { features.insert(.greekParse) }
            if SWModule_hasFeature(handle, "HebrewParse") != 0 { features.insert(.hebrewParse) }
            if SWModule_hasFeature(handle, "DailyDevotion") != 0 { features.insert(.dailyDevotion) }
            return features
        }

        return ModuleFeatures.fromConfigValues(featureValues)
    }
}
