import Foundation
import BibleCore
import BibleView
import SwordKit
import os.log

private let multiReferenceDocumentBuilderLogger = Logger(
    subsystem: "org.andbible",
    category: "BibleReaderMultiReferenceDocumentBuilder"
)

/**
 Builds Android-style Bible `MultiDocument` payloads from source-aware reference links.

 Android resolves each `BibleLink` in its declared versification and optional document, then emits
 one fragment per successfully resolved `BookAndKey`. This builder applies the same boundary: source
 coordinates are converted authoritatively into each fragment's target module before its ordinal
 or content is read. It never substitutes active-pane coordinates or relabels source ordinals.
 */
struct BibleReaderMultiReferenceDocumentBuilder {
    /// Global installed-book resolver used for explicit and active target identities.
    private let moduleResolver: BibleReaderInstalledModuleResolver
    /// Active Bible initials used only when a link does not force a document.
    private let activeModuleName: String

    /**
     Creates a source-aware multi-reference builder.

     - Parameters:
       - swordManager: Manager used to resolve explicitly targeted modules.
       - activeModule: Current Bible target for links without an explicit document.
       - activeModuleName: Current Bible initials.
     - Side effects: None during construction.
     - Failure modes: Missing target modules are handled per link by omitting that fragment.
     */
    init(swordManager: SwordManager?, activeModule: SwordModule?, activeModuleName: String) {
        self.moduleResolver = BibleReaderInstalledModuleResolver(
            swordManager: swordManager,
            sqliteModules: []
        )
        self.activeModuleName = activeModuleName
    }

    /** Creates a builder from the pane's shared SWORD/SQLite resolver and active identity. */
    init(
        moduleResolver: BibleReaderInstalledModuleResolver,
        activeModuleName: String
    ) {
        self.moduleResolver = moduleResolver
        self.activeModuleName = activeModuleName
    }

    /**
     Builds the Vue `MultiDocument` payload Android uses for mixed reference links.

     - Parameter refs: References carrying their own source versification and optional target module.
     - Returns: Serialized JSON containing every resolvable fragment in input order, or `nil` when
       no link maps to readable content.
     - Side effects: Resolves installed modules and reads exact SWORD entries while restoring each
       module cursor.
     - Failure modes: Unknown target modules, non-authoritative conversions, unaddressable verses,
       empty entries, and encoding failures omit the affected link or return `nil`; no fallback
       fragment is fabricated.
     */
    func buildDocumentJSON(refs: [OsisRef]) -> String? {
        let fragments = refs.compactMap(buildFragment(for:))
        guard !fragments.isEmpty else { return nil }

        let payload = MultiFragmentDocumentPayload(
            id: "multi-\(UUID().uuidString)",
            type: "multi",
            osisFragments: fragments,
            compare: false,
            contentType: nil,
            state: nil
        )
        guard let data = try? bridgeEncoder.encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            multiReferenceDocumentBuilderLogger.error("Failed to encode multi-reference document JSON")
            return nil
        }
        return json
    }

    /** Converts one complete source passage into its target module and renders it atomically. */
    private func buildFragment(for ref: OsisRef) -> OsisFragment? {
        guard let source = targetSource(for: ref) else { return nil }
        var mappedReferences: [VerseKeyReference] = []
        for sourceReference in ref.sourceVerses {
            guard let reference = source.mappedReference(
                      osisBookId: sourceReference.osisBookId,
                      chapter: sourceReference.chapter,
                      verse: sourceReference.verse,
                      from: ref.sourceVersification
                  ) else {
                return nil
            }
            if let previous = mappedReferences.last {
                if previous == reference { continue }
                guard source.isCanonicallyAdjacent(reference, after: previous) else {
                    return nil
                }
            }
            mappedReferences.append(reference)
        }
        return BibleReaderInstalledScriptureFragmentBuilder.build(
            source: source,
            references: mappedReferences,
            requiresCompleteContent: true
        )
    }

    /** Resolves Android's optional per-link document target without inferring a source domain. */
    private func targetSource(for ref: OsisRef) -> BibleReaderInstalledScriptureSource? {
        if let initials = ref.targetBookInitials, !initials.isEmpty {
            return moduleResolver.scripture(named: initials)
        }
        return moduleResolver.scripture(named: activeModuleName)
    }

    /**
     Reads one exact Bible verse as an OSIS fragment suitable for Vue `MultiDocument`.

     - Parameters:
       - ref: Reference already converted into `module`'s versification.
       - module: Target Bible module.
       - ordinal: Target-module ordinal for `ref`.
     - Returns: A verse wrapper containing non-empty target-module OSIS, or `nil` when the exact
       target key cannot be read.
     - Side effects: Temporarily moves the module cursor and restores it before returning.
     - Failure modes: Missing modules, nearest-key substitutions, and empty entries return `nil`;
       no display-label fallback is emitted as scripture content.
     */
    static func buildBibleMultiReferenceXML(
        ref: OsisRef,
        module: SwordModule?,
        ordinal: Int
    ) -> String? {
        guard let module else { return nil }
        let osisRef = "\(ref.osisId).\(ref.chapter).\(ref.verse)"
        let inspection = module.inspectVerseKeyAndRawEntryRestoringPrevious("=\(osisRef)")
        guard let key = inspection.verseKey,
              key.osisBookName == ref.osisId,
              key.chapter == ref.chapter,
              key.verse == ref.verse else {
            return nil
        }
        let rawText = inspection.rawEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty else { return nil }
        return "<div><verse osisID=\"\(osisRef)\" verseOrdinal=\"\(ordinal)\">\(rawText) </verse></div>"
    }

    /**
     Renders one already-target-owned Bible passage as a single Android Multi fragment.

     - Parameters:
       - module: Bible module whose versification owns every supplied reference.
       - references: Ordered, concrete target-module verses comprising one source passage.
       - persistedOsisRef: Optional Android persistence key. When absent, the rendered first and
         last references define the normalized key.
     - Returns: One fragment containing every requested verse in order, or `nil` if any verse is
       missing, empty, normalized to another key, or outside the module.
     - Side effects: Reads exact module entries through cursor-restoring inspectors.
     - Failure modes: Passage rendering is atomic; a partial fragment is never returned.
     */
    static func buildBiblePassageFragment(
        module: SwordModule,
        references: [VerseKeyReference],
        persistedOsisRef: String? = nil
    ) -> OsisFragment? {
        BibleReaderInstalledScriptureFragmentBuilder.build(
            source: .sword(module),
            references: references,
            persistedOsisRef: persistedOsisRef,
            requiresCompleteContent: true
        )
    }

    /**
     Expands SWORD's normalized key-list output into concrete references owned by one module.

     - Parameters:
       - parsedKeys: Values returned by `SwordModule.parseKeyList`, in parser order.
       - module: Module whose versification and ordinal domain own those keys.
     - Returns: Ordered concrete verses with adjacent parser duplicates removed, or `nil` when any
       normalized key cannot be resolved completely and exactly.
     - Side effects: Reads module ordinals/references through cursor-restoring SWORD helpers.
     - Failure modes: Malformed endpoints, reversed ranges, introductions, and unavailable verses
       fail the complete passage rather than returning a truncated fragment.
     */
    static func concreteReferences(
        parsedKeys: [String],
        module: SwordModule
    ) -> [VerseKeyReference]? {
        concreteReferences(parsedKeys: parsedKeys, source: .sword(module))
    }

    /** Expands normalized persisted keys against an exact SWORD or SQLite source. */
    static func concreteReferences(
        parsedKeys: [String],
        source: BibleReaderInstalledScriptureSource
    ) -> [VerseKeyReference]? {
        guard !parsedKeys.isEmpty else { return nil }
        var references: [VerseKeyReference] = []
        for parsedKey in parsedKeys {
            let endpoints = parsedKey.split(separator: "-", maxSplits: 1).map(String.init)
            guard let start = concreteReference(
                      endpoints[0],
                      inheriting: nil,
                      source: source
                  ) else { return nil }
            let end: VerseKeyReference
            if endpoints.count == 2 {
                guard let parsedEnd = concreteReference(
                          endpoints[1],
                          inheriting: start,
                          source: source
                      ) else { return nil }
                end = parsedEnd
            } else {
                end = start
            }
            guard start.ordinal <= end.ordinal else { return nil }

            for ordinal in start.ordinal...end.ordinal {
                guard let reference = source.verseReference(ordinal: ordinal),
                      reference.verse > 0 else { continue }
                if references.last != reference {
                    references.append(reference)
                }
            }
        }
        return references.isEmpty ? nil : references
    }

    /** Resolves one normalized full or inherited range endpoint against its owning module. */
    private static func concreteReference(
        _ token: String,
        inheriting start: VerseKeyReference?,
        source: BibleReaderInstalledScriptureSource
    ) -> VerseKeyReference? {
        let parts = token
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".", omittingEmptySubsequences: true)
            .map(String.init)
        let osisBookId: String
        let chapter: Int
        let verse: Int
        switch parts.count {
        case 3:
            osisBookId = parts[0]
            guard let parsedChapter = Int(parts[1]),
                  let parsedVerse = Int(parts[2]) else { return nil }
            chapter = parsedChapter
            verse = parsedVerse
        case 2:
            guard let start,
                  let parsedChapter = Int(parts[0]),
                  let parsedVerse = Int(parts[1]) else { return nil }
            osisBookId = start.osisBookId
            chapter = parsedChapter
            verse = parsedVerse
        case 1:
            guard let start, let parsedVerse = Int(parts[0]) else { return nil }
            osisBookId = start.osisBookId
            chapter = start.chapter
            verse = parsedVerse
        default:
            return nil
        }
        guard verse > 0,
              let ordinal = source.verseOrdinal(
                  osisBookId: osisBookId,
                  chapter: chapter,
                  verse: verse
              ) else { return nil }
        return VerseKeyReference(
            osisBookId: osisBookId,
            chapter: chapter,
            verse: verse,
            ordinal: ordinal
        )
    }

}
