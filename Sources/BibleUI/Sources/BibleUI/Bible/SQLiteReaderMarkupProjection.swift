// SQLiteReaderMarkupProjection.swift -- Source-safe SQLite Bible markup projection

import BibleCore
import Foundation
import SwordKit

/**
 Projects Android SQLite Bible text into native OSIS and speech-safe forms.

 MyBible and MySword readers already return source markup or transformed OSIS. e-Sword `.bblx`
 returns escaped converted RTF, while `.bbli` is intentionally plain text and may contain literal
 XML-significant characters. Only that plain-text format is escaped for the OSIS document; its
 speech fallback remains the exact visible source text.
 */
enum SQLiteReaderMarkupProjection {
    /**
     Returns source markup suitable for insertion inside an OSIS verse element.

     - Parameters:
       - text: Exact verse text returned by the format reader.
       - module: Source metadata identifying plain `.bbli` e-Sword content.
     - Returns: Original structural markup, or XML-escaped plain e-Sword text.
     - Side effects: None.
     - Failure modes: None; format identity, rather than markup guessing, controls escaping.
     */
    static func bibleVerseXML(
        _ text: String,
        module: BibleReaderSQLiteModuleHandle
    ) -> String {
        guard isPlainESword(module) else { return text }
        return SQLiteDocumentXMLCompatibility.escapedText(text)
    }

    /**
     Returns visible source text for speech and native copy/share actions.

     - Parameters:
       - text: Exact source markup or plain text.
       - module: Source format metadata controlling projection.
     - Returns: Trimmed visible text with supported markup removed.
     - Side effects: None.
     - Failure modes: Malformed structural markup falls back to the shared generic XML text
       projection; no alternate content backend is consulted.
     */
    static func plainText(
        _ text: String,
        module: BibleReaderSQLiteModuleHandle
    ) -> String {
        if isPlainESword(module) {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let sourceXML = "<div>\(text)</div>"
        if let fragment = try? SwordOSISFragmentProcessor.process(
            sourceXML: sourceXML,
            category: .bible,
            moduleInitials: module.info.name
        ), let plainText = fragment.comparablePlainText {
            return plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return GenericBookmarkSourceTextProjection.xhtmlText(sourceXML)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /**
     Identifies e-Sword's plain-text `.bbli` storage without guessing from content.

     - Parameter module: Validated source handle.
     - Returns: True only for e-Sword metadata whose source extension is exactly `.bbli`
       case-insensitively.
     - Side effects: None.
     - Failure modes: Missing or different extensions return false.
     */
    private static func isPlainESword(_ module: BibleReaderSQLiteModuleHandle) -> Bool {
        module.metadata.format == .eSword
            && module.metadata.sourceURL.pathExtension.caseInsensitiveCompare("bbli") == .orderedSame
    }
}
