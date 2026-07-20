import Foundation
import BibleCore
import BibleView
import SwordKit
import os.log

private let compareDocumentBuilderLogger = Logger(subsystem: "org.andbible", category: "BibleReaderCompareDocumentBuilder")

/**
 Builds Android-style Compare `MultiDocument` payloads.

 `BibleReaderController` owns bridge orchestration and stale async request protection. This builder
 owns Compare-specific module selection, verse extraction, range labeling, and typed bridge payload
 assembly so the controller does not need to carry document-construction rules.
 */
struct BibleReaderCompareDocumentBuilder {
    /// Active SWORD manager used to resolve cached `ModuleInfo` entries into module readers.
    private let swordManager: SwordManager?
    /// Cached installed Bible metadata from the controller, used before falling back to SWORD.
    private let installedBibleModules: [ModuleInfo]
    /// Active Bible initials; Compare should present this module first when it is installed.
    private let activeModuleName: String

    /**
     Captures all main-reader state needed to build a compare payload away from the main queue.
     */
    struct Request {
        /// Modules to include in compare output, paired with their SWORD readers.
        let modules: [(info: ModuleInfo, module: SwordModule)]
        /// Active passage OSIS book id.
        let osisBookId: String
        /// User-facing active book name.
        let bookName: String
        /// One-based active chapter.
        let chapter: Int
        /// Whether the active book is in the New Testament.
        let isNewTestament: Bool
        /// Optional first selected verse.
        let startVerse: Int?
        /// Optional last selected verse.
        let endVerse: Int?
    }

    /**
     Creates a Compare document builder for one reader pane.

     - Parameters:
       - swordManager: Active SWORD manager for module resolution.
       - installedBibleModules: Cached installed Bible metadata from the reader.
       - activeModuleName: Active Bible initials used to order compare fragments.
     - Side effects: None during construction.
     - Failure modes: Missing SWORD is handled by `makeRequest(...)`.
     */
    init(
        swordManager: SwordManager?,
        installedBibleModules: [ModuleInfo],
        activeModuleName: String
    ) {
        self.swordManager = swordManager
        self.installedBibleModules = installedBibleModules
        self.activeModuleName = activeModuleName
    }

    /**
     Builds a background-safe Compare request from current reader passage state.

     - Parameters:
       - osisBookId: Active passage OSIS book id.
       - bookName: User-facing active book name.
       - chapter: One-based active chapter.
       - isNewTestament: Whether the active book is in the New Testament.
       - startVerse: Optional first selected verse.
       - endVerse: Optional final selected verse.
     - Returns: Captured request containing module readers, or `nil` when Compare cannot render.
     - Side effects: Resolves installed modules through SWORD.
     - Failure modes: Logs and returns `nil` when SWORD is unavailable or no Bible modules exist.
     */
    func makeRequest(
        osisBookId: String,
        bookName: String,
        chapter: Int,
        isNewTestament: Bool,
        startVerse: Int?,
        endVerse: Int?
    ) -> Request? {
        guard let manager = swordManager else {
            compareDocumentBuilderLogger.warning("Compare requested without an active SwordManager")
            return nil
        }

        let modules = installedCompareBibleModules(using: manager).compactMap { moduleInfo in
            manager.module(named: moduleInfo.name).map { (info: moduleInfo, module: $0) }
        }
        guard !modules.isEmpty else {
            compareDocumentBuilderLogger.warning("Compare requested with no installed Bible modules")
            return nil
        }

        return Request(
            modules: modules,
            osisBookId: osisBookId,
            bookName: bookName,
            chapter: chapter,
            isNewTestament: isNewTestament,
            startVerse: startVerse,
            endVerse: endVerse
        )
    }

    /**
     Builds the Vue `MultiDocument` payload Android uses for Compare.

     - Parameter request: Captured compare request containing module readers and passage metadata.
     - Returns: Serialized compare `MultiDocument`, or `nil` when no installed Bible can render the
       requested range.
     - Side effects: Temporarily moves each module cursor while extracting raw OSIS.
     - Failure modes: Logs and returns `nil` when every module misses the requested range or JSON
       serialization fails.
     */
    static func buildDocumentJSON(_ request: Request) -> String? {
        let fragments = request.modules.compactMap { modulePair -> OsisFragment? in
            buildFragment(
                module: modulePair.module,
                moduleInfo: modulePair.info,
                osisBookId: request.osisBookId,
                bookName: request.bookName,
                chapter: request.chapter,
                isNewTestament: request.isNewTestament,
                startVerse: request.startVerse,
                endVerse: request.endVerse
            )
        }

        guard !fragments.isEmpty else {
            compareDocumentBuilderLogger.warning(
                "Compare requested but no module rendered \(request.osisBookId, privacy: .public) \(request.chapter)"
            )
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
     Resolves installed Bible modules eligible for Compare.

     - Parameter manager: Active SWORD manager used as a fallback when cached module metadata is
       empty.
     - Returns: Installed Bible module metadata in active-reader order.
     - Side effects: May read the SWORD module list when cached `installedBibleModules` is empty.
     - Failure modes: Returns an empty array when no installed module is categorized as a Bible.
     */
    private func installedCompareBibleModules(using manager: SwordManager) -> [ModuleInfo] {
        // `installedModules()` already excludes unsupported modules (ADR-0010), so filtering by
        // category matches the cached `installedBibleModules` the coordinator builds.
        let modules = installedBibleModules.isEmpty
            ? manager.installedModules().filter { $0.category == .bible }
            : installedBibleModules

        guard let activeIndex = modules.firstIndex(where: { $0.name == activeModuleName }) else {
            return modules
        }
        var orderedModules = modules
        let activeModule = orderedModules.remove(at: activeIndex)
        orderedModules.insert(activeModule, at: 0)
        return orderedModules
    }

    /**
     Builds one compare fragment for one installed Bible module.

     - Parameters:
       - module: SWORD Bible module to read.
       - moduleInfo: Metadata for `module`, used for Vue labels and language/direction flags.
       - osisBookId: Active passage OSIS book identifier.
       - bookName: User-facing active book name.
       - chapter: One-based active chapter number.
       - startVerse: Optional one-based first verse to compare.
       - endVerse: Optional one-based final verse to compare.
     - Returns: Vue OSIS fragment, or `nil` when the module cannot resolve any verse in the
       requested range.
     - Side effects: Temporarily moves the SWORD module cursor once per inspected verse and restores
       the previous cursor after each read.
     - Failure modes: Returns `nil` if the first requested verse cannot be resolved in the target
       module's versification or if all raw entries in the range are empty.
     */
    private static func buildFragment(
        module: SwordModule,
        moduleInfo: ModuleInfo,
        osisBookId: String,
        bookName: String,
        chapter: Int,
        isNewTestament: Bool,
        startVerse: Int?,
        endVerse: Int?
    ) -> OsisFragment? {
        let normalizedStart = max(1, startVerse ?? 1)
        let firstInspection = module.inspectVerseKeyAndRawEntryRestoringPrevious(
            "=\(osisBookId).\(chapter).\(normalizedStart)"
        )
        guard let firstKey = firstInspection.verseKey,
              firstKey.osisBookName == osisBookId,
              firstKey.chapter == chapter,
              firstKey.verse == normalizedStart else {
            return nil
        }

        let chapterMaxVerse = max(normalizedStart, firstKey.verseMax)
        let normalizedEnd = min(max(normalizedStart, endVerse ?? chapterMaxVerse), chapterMaxVerse)
        var verseXML: [String] = []

        for verse in normalizedStart...normalizedEnd {
            guard let ordinal = module.verseOrdinal(osisBookId: osisBookId, chapter: chapter, verse: verse) else {
                return nil
            }
            let inspection: (actualKey: String, verseKey: VerseKeyChildren?, rawEntry: String)
            if verse == normalizedStart {
                inspection = firstInspection
            } else {
                inspection = module.inspectVerseKeyAndRawEntryRestoringPrevious(
                    "=\(osisBookId).\(chapter).\(verse)"
                )
            }

            guard let key = inspection.verseKey,
                  key.osisBookName == osisBookId,
                  key.chapter == chapter,
                  key.verse == verse else {
                continue
            }

            let rawText = inspection.rawEntry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawText.isEmpty else { continue }

            let osisRef = "\(osisBookId).\(chapter).\(verse)"
            verseXML.append(
                "<verse osisID=\"\(osisRef)\" verseOrdinal=\"\(ordinal)\">\(rawText) </verse>"
            )
        }

        guard !verseXML.isEmpty else { return nil }

        let osisRef = compareOsisRef(
            osisBookId: osisBookId,
            chapter: chapter,
            startVerse: normalizedStart,
            endVerse: normalizedEnd
        )
        let keyName = compareRangeTitle(
            bookName: bookName,
            chapter: chapter,
            startVerse: normalizedStart,
            endVerse: normalizedEnd
        )
        guard let ordinalStart = module.verseOrdinal(osisBookId: osisBookId, chapter: chapter, verse: normalizedStart),
              let ordinalEnd = module.verseOrdinal(osisBookId: osisBookId, chapter: chapter, verse: normalizedEnd) else {
            return nil
        }

        return OsisFragment(
            xml: "<div>\(verseXML.joined())</div>",
            key: "\(moduleInfo.name)--\(osisRef)",
            keyName: keyName,
            v11n: "KJVA",
            bookCategory: DocumentCategory.bible.rawValue,
            bookInitials: moduleInfo.name,
            bookAbbreviation: moduleInfo.name,
            osisRef: osisRef,
            isNewTestament: isNewTestament,
            features: OsisFeatures(),
            hasStrongs: moduleInfo.features.contains(.strongsNumbers),
            ordinalRange: [ordinalStart, ordinalEnd],
            language: moduleInfo.language.isEmpty ? "en" : moduleInfo.language,
            direction: moduleInfo.isRightToLeft ? "rtl" : "ltr"
        )
    }

    /**
     Formats the OSIS reference carried by a compare fragment.

     - Parameters:
       - osisBookId: OSIS book identifier already resolved for the active reader book.
       - chapter: One-based chapter number for the compare passage.
       - startVerse: Normalized first verse in the rendered range.
       - endVerse: Normalized last verse in the rendered range.
     - Returns: Single-verse OSIS ref or Android-style repeated-book range ref.
     - Side effects: None.
     - Failure modes: None; callers normalize and validate the verse range before formatting.
     */
    private static func compareOsisRef(
        osisBookId: String,
        chapter: Int,
        startVerse: Int,
        endVerse: Int
    ) -> String {
        if startVerse == endVerse {
            return "\(osisBookId).\(chapter).\(startVerse)"
        }
        return "\(osisBookId).\(chapter).\(startVerse)-\(osisBookId).\(chapter).\(endVerse)"
    }

    /**
     Formats the user-visible compare range title used by Vue `MultiDocument`.

     - Parameters:
       - bookName: User-facing book name from the active reader state.
       - chapter: One-based chapter number for the compare passage.
       - startVerse: Normalized first verse in the rendered range.
       - endVerse: Normalized last verse in the rendered range.
     - Returns: Android-compatible range title such as `Genesis 1:1` or `Genesis 1:1-3`.
     - Side effects: None.
     - Failure modes: None; callers normalize and validate the verse range before formatting.
     */
    private static func compareRangeTitle(
        bookName: String,
        chapter: Int,
        startVerse: Int,
        endVerse: Int
    ) -> String {
        if startVerse == endVerse {
            return "\(bookName) \(chapter):\(startVerse)"
        }
        return "\(bookName) \(chapter):\(startVerse)-\(endVerse)"
    }
}
