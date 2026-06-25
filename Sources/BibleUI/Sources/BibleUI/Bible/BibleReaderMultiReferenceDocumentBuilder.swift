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
 Builds Android-style Bible `MultiDocument` payloads for OSIS and multi-reference links.

 Android resolves cross-reference lists through `LinkControl.openMulti(...)` into
 `FakeBookFactory.multiDocument`. This builder owns the equivalent iOS payload construction so the
 reader controller supplies only active-module state and window orchestration.
 */
struct BibleReaderMultiReferenceDocumentBuilder {
    /// Active Bible module used to resolve ordinals and extract raw OSIS fragments.
    private let activeModule: SwordModule?
    /// Active Bible module initials used in fragment identity when no source module override exists.
    private let activeModuleName: String
    /// Legacy ordinal fallback used only when no module can resolve a verse.
    private let compatibilityOrdinal: (_ chapter: Int, _ verse: Int) -> Int
    /// Book-test helper supplied by the controller's current book catalog.
    private let isNewTestament: (_ bookName: String) -> Bool

    /**
     Creates a multi-reference document builder for one reader pane.

     - Parameters:
       - activeModule: Active Bible module, if one is loaded.
       - activeModuleName: Active Bible initials to attach to generated fragments.
       - compatibilityOrdinal: Fallback ordinal projection for no-module startup states.
       - isNewTestament: Book classification closure from the controller's active catalog.
     - Side effects: None during construction.
     - Failure modes: Missing active module is handled by fallback fragment generation.
     */
    init(
        activeModule: SwordModule?,
        activeModuleName: String,
        compatibilityOrdinal: @escaping (_ chapter: Int, _ verse: Int) -> Int,
        isNewTestament: @escaping (_ bookName: String) -> Bool
    ) {
        self.activeModule = activeModule
        self.activeModuleName = activeModuleName
        self.compatibilityOrdinal = compatibilityOrdinal
        self.isNewTestament = isNewTestament
    }

    /**
     Builds the Vue `MultiDocument` payload Android uses for multi-reference Bible links.

     - Parameter refs: Parsed OSIS references in the order supplied by an Android-compatible link.
     - Returns: Serialized JSON for a transient multi-document, or `nil` if no complete fragment
       set can be produced.
     - Side effects: Reads the active SWORD Bible module and may temporarily move its key cursor
       while extracting verse OSIS.
     - Failure modes: Returns `nil` when any requested reference cannot be resolved by the active
       module, preserving the pre-existing all-or-nothing document contract.
     */
    func buildDocumentJSON(refs: [OsisRef]) -> String? {
        guard !refs.isEmpty else { return nil }

        let fragments: [[String: Any]] = refs.compactMap { ref in
            let osisRef = "\(ref.osisId).\(ref.chapter).\(ref.verse)"
            let ordinal: Int
            if let activeModule {
                guard let moduleOrdinal = activeModule.verseOrdinal(
                    osisBookId: ref.osisId,
                    chapter: ref.chapter,
                    verse: ref.verse
                ) else {
                    return nil
                }
                ordinal = moduleOrdinal
            } else {
                ordinal = compatibilityOrdinal(ref.chapter, ref.verse)
            }
            return [
                "xml": Self.buildBibleMultiReferenceXML(ref: ref, module: activeModule, ordinal: ordinal),
                "key": "\(activeModuleName)--\(osisRef)",
                "keyName": ref.displayName,
                "v11n": "KJVA",
                "bookCategory": DocumentCategory.bible.rawValue,
                "bookInitials": activeModuleName,
                "bookAbbreviation": ref.osisId,
                "osisRef": osisRef,
                "isNewTestament": isNewTestament(ref.book),
                "features": [String: Any](),
                "hasStrongs": activeModule?.info.features.contains(.strongsNumbers) ?? false,
                "ordinalRange": [ordinal, ordinal],
                "language": "en",
                "direction": "ltr",
            ]
        }
        guard fragments.count == refs.count else { return nil }

        let document: [String: Any] = [
            "id": "multi-\(UUID().uuidString)",
            "type": "multi",
            "osisFragments": fragments,
            "compare": false,
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            multiReferenceDocumentBuilderLogger.error("Failed to serialize multi-reference document JSON")
            return nil
        }
        return json
    }

    /**
     Reads one Bible verse as an OSIS fragment suitable for Vue `MultiDocument`.

     - Parameters:
       - ref: Parsed Bible reference to render.
       - module: Bible module to read from. A missing module yields a fallback fragment.
       - ordinal: Verse ordinal to write into the fragment.
     - Returns: A `<div>` containing one `<verse>` element.
     - Side effects: When `module` is present, temporarily moves its SWORD key cursor inside a
       serialized inspection call and restores the previous cursor before returning.
     - Failure modes: Missing or mismatched module content falls back to the escaped display label.
     */
    static func buildBibleMultiReferenceXML(ref: OsisRef, module: SwordModule?, ordinal: Int) -> String {
        let osisRef = "\(ref.osisId).\(ref.chapter).\(ref.verse)"
        let rawText: String

        if let module {
            let inspection = module.inspectVerseKeyAndRawEntryRestoringPrevious("=\(osisRef)")
            if let key = inspection.verseKey,
               key.osisBookName == ref.osisId,
               key.chapter == ref.chapter,
               key.verse == ref.verse {
                rawText = inspection.rawEntry.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                rawText = ""
            }
        } else {
            rawText = ""
        }

        let body = rawText.isEmpty ? escapeXML(ref.displayName) : rawText
        return "<div><verse osisID=\"\(osisRef)\" verseOrdinal=\"\(ordinal)\">\(body) </verse></div>"
    }

    /**
     Escapes text inserted into synthetic XML fallback fragments.

     - Parameter text: Plain text fallback label.
     - Returns: Text with XML-sensitive characters escaped.
     - Side effects: None.
     - Failure modes: None.
     */
    private static func escapeXML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
