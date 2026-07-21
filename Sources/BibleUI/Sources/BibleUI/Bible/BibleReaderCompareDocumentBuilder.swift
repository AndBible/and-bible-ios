import Foundation
import BibleCore
import BibleView
import SwordKit
import os.log

private let compareDocumentBuilderLogger = Logger(subsystem: "org.andbible", category: "BibleReaderCompareDocumentBuilder")

/**
 Builds Android-style Compare `MultiDocument` payloads from the selected fragment's verse domain.

 The selected fragment owns the incoming ordinals. Each SWORD or SQLite target receives an
 authoritative conversion before content is read, so Compare never reinterprets source ordinals
 through the active pane or relabels them as another module's versification.
 */
struct BibleReaderCompareDocumentBuilder {
    /// Global installed-book resolver shared by every source and target decision.
    private let moduleResolver: BibleReaderInstalledModuleResolver
    /// Cached installed Bible metadata from the controller.
    private let installedBibleModules: [ModuleInfo]

    /** Captured, background-safe source range and target module set for one Compare action. */
    struct Request {
        /// Sources to include in compare output, with the selected source ordered first.
        let sources: [BibleReaderInstalledScriptureSource]
        /// Exact selected-fragment module initials.
        let sourceBookInitials: String
        /// Exact selected-fragment versification.
        let sourceVersification: String
        /// First selected verse in the source module's ordinal domain.
        let sourceStart: VerseKeyReference
        /// Last selected verse in the source module's ordinal domain.
        let sourceEnd: VerseKeyReference
    }

    /**
     Creates a Compare builder for installed reader Bibles.

     - Parameters:
       - swordManager: SWORD manager used for exact native module lookup.
       - installedBibleModules: Installed Bible metadata snapshot.
     - Side effects: None.
     - Failure modes: Missing state is rejected by `makeRequest`.
     */
    init(
        swordManager: SwordManager?,
        installedBibleModules: [ModuleInfo],
        sqliteModules: [BibleReaderSQLiteModuleHandle] = []
    ) {
        self.moduleResolver = BibleReaderInstalledModuleResolver(
            swordManager: swordManager,
            sqliteModules: sqliteModules
        )
        self.installedBibleModules = installedBibleModules
    }

    /** Creates a builder from the controller's already-captured global installed-book resolver. */
    init(
        moduleResolver: BibleReaderInstalledModuleResolver,
        installedBibleModules: [ModuleInfo]
    ) {
        self.moduleResolver = moduleResolver
        self.installedBibleModules = installedBibleModules
    }

    /**
     Captures the selected fragment's range without consulting active-pane passage state.

     - Parameters:
       - bookInitials: Module initials carried by the selection event.
       - startOrdinal: First source-module ordinal.
       - endOrdinal: Last source-module ordinal; non-positive values mean a single verse.
     - Returns: A source-aware request, or `nil` when identity/range/module resolution fails.
     - Side effects: Resolves installed modules and performs cursor-restoring/static verse lookups.
     - Failure modes: Unknown modules, invalid ordinals, reversed ranges, and empty target sets fail
       closed; no active-module or KJVA fallback is used.
     */
    func makeRequest(bookInitials: String, startOrdinal: Int, endOrdinal: Int) -> Request? {
        guard let source = moduleResolver.scripture(named: bookInitials),
              let sourceStart = source.verseReference(ordinal: startOrdinal) else {
            compareDocumentBuilderLogger.warning("Compare source module/range was unavailable")
            return nil
        }
        let effectiveEndOrdinal = endOrdinal > 0 ? endOrdinal : startOrdinal
        guard let sourceEnd = source.verseReference(ordinal: effectiveEndOrdinal),
              sourceStart.ordinal <= sourceEnd.ordinal else {
            compareDocumentBuilderLogger.warning("Compare source range was invalid")
            return nil
        }

        let sources = installedCompareBibleSources(source: source)
        guard !sources.isEmpty else {
            compareDocumentBuilderLogger.warning("Compare requested with no installed Bible modules")
            return nil
        }
        return Request(
            sources: sources,
            sourceBookInitials: source.info.name,
            sourceVersification: source.versificationName,
            sourceStart: sourceStart,
            sourceEnd: sourceEnd
        )
    }

    /**
     Builds the Vue Compare document, converting the selected range independently for each target.

     - Parameter request: Source-aware Compare request.
     - Returns: Serialized `MultiDocument`, or `nil` when no target can authoritatively map/render.
     - Side effects: Reads target module entries while preserving each module cursor.
     - Failure modes: Targets with missing authoritative mappings or content are omitted. Complete
       failure or bridge encoding failure returns `nil`.
     */
    static func buildDocumentJSON(_ request: Request) -> String? {
        let fragments = request.sources.compactMap { source in
            buildFragment(
                source: source,
                sourceVersification: request.sourceVersification,
                sourceStart: request.sourceStart,
                sourceEnd: request.sourceEnd
            )
        }
        guard !fragments.isEmpty else {
            compareDocumentBuilderLogger.warning("No Compare target mapped the selected source range")
            return nil
        }
        let payload = MultiFragmentDocumentPayload(
            id: "compare-\(UUID().uuidString)",
            type: "multi",
            osisFragments: fragments,
            compare: true,
            contentType: nil,
            state: nil
        )
        guard let data = try? bridgeEncoder.encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            compareDocumentBuilderLogger.error("Failed to encode compare document JSON")
            return nil
        }
        return json
    }

    /**
     Resolves installed Bible sources eligible for Compare and puts the selection source first.

     - Parameters:
       - source: Exact installed Bible carried by the selected fragment.
     - Returns: Installed SWORD/SQLite sources with the selection source first.
     - Side effects: None after resolver construction.
     - Failure modes: Returns an empty array when no installed module is categorized as a Bible.
     */
    private func installedCompareBibleSources(
        source: BibleReaderInstalledScriptureSource
    ) -> [BibleReaderInstalledScriptureSource] {
        var sources = moduleResolver.modules(
            category: .bible,
            orderedBy: installedBibleModules
        ).compactMap(\.scripture)
        if let index = sources.firstIndex(where: { $0.info.name == source.info.name }) {
            sources.insert(sources.remove(at: index), at: 0)
        } else {
            sources.insert(source, at: 0)
        }
        return sources
    }

    /**
     Converts and renders one selected range in a target module's own versification.

     - Parameters:
       - source: Target installed Bible.
       - sourceVersification: Domain owning `sourceStart` and `sourceEnd`.
       - sourceStart: First selected source verse.
       - sourceEnd: Last selected source verse.
     - Returns: Target-domain fragment, or `nil` for any non-authoritative/unaddressable conversion.
     - Side effects: Performs one bounded target read; SWORD restores its cursor and SQLite owns its
       read-only connection.
     - Failure modes: Never uses `VersificationMapper` public fallback and never substitutes source
       ordinals for target ordinals.
     */
    private static func buildFragment(
        source: BibleReaderInstalledScriptureSource,
        sourceVersification: String,
        sourceStart: VerseKeyReference,
        sourceEnd: VerseKeyReference
    ) -> OsisFragment? {
        guard let mappedStart = source.mappedReference(
                  osisBookId: sourceStart.osisBookId,
                  chapter: sourceStart.chapter,
                  verse: sourceStart.verse,
                  from: sourceVersification
              ),
              let mappedEnd = source.mappedReference(
                  osisBookId: sourceEnd.osisBookId,
                  chapter: sourceEnd.chapter,
                  verse: sourceEnd.verse,
                  from: sourceVersification
              ),
              mappedStart.ordinal <= mappedEnd.ordinal else {
            return nil
        }
        let references = (mappedStart.ordinal...mappedEnd.ordinal).compactMap {
            source.verseReference(ordinal: $0)
        }
        return BibleReaderInstalledScriptureFragmentBuilder.build(
            source: source,
            references: references,
            requiresCompleteContent: false
        )
    }
}
