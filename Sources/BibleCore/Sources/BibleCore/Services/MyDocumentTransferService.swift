// MyDocumentTransferService.swift -- Android-compatible My Documents text transfer

import Foundation

/**
 Converts native text files to and from My Documents drafts.

 The filename ordering, HTML detection, numeric document-prefix removal, extension selection, and
 ASCII export-name sanitization intentionally mirror Android's `MyDocumentsActivity` and
 `MyDocumentPagesActivity` contracts.
 */
public enum MyDocumentTransferService {
    /**
     Converts selected text files into ordered page drafts.

     - Parameters:
       - files: UTF-8 text file names and bodies.
       - stripsDocumentOrderPrefix: Whether leading Android export prefixes such as `01-` should be
         removed. Document import uses `true`; single-page import uses `false`.
     - Returns: Pages sorted by file name when more than one file is supplied.
     - Side effects: None.
     - Failure modes: Throws `emptyImport` when no files are supplied.
     */
    public static func importPages(
        from files: [MyDocumentImportFile],
        stripsDocumentOrderPrefix: Bool
    ) throws -> [MyDocumentPageDraft] {
        guard !files.isEmpty else {
            throw MyDocumentManagementError.emptyImport
        }
        // Kotlin's `sortedBy { fileName }` is a locale-independent lexical comparison.
        let orderedFiles = files.sorted { $0.fileName < $1.fileName }
        return orderedFiles.enumerated().map { index, file in
            let rawTitle = deletingFinalPathExtension(file.fileName)
            let strippedTitle: String
            if stripsDocumentOrderPrefix {
                strippedTitle = rawTitle.replacingOccurrences(
                    of: "^\\d+-",
                    with: "",
                    options: .regularExpression
                )
            } else {
                strippedTitle = rawTitle
            }
            let title = strippedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackTitle = String(
                format: String(localized: "my_document_new_page_name", defaultValue: "Page %d"),
                index + 1
            )
            return MyDocumentPageDraft(
                title: title.isEmpty ? fallbackTitle : title,
                contentType: contentType(forFileName: file.fileName),
                orderNumber: index,
                languageCode: Locale.current.language.languageCode?.identifier,
                content: file.content
            )
        }
    }

    /** Exports every page in display order with Android's two-digit order prefix. */
    public static func exportDocument(_ document: MyDocumentDraft) -> [MyDocumentExportFile] {
        document.pages.sorted(by: pageOrder).enumerated().map { index, page in
            exportFile(for: page, orderPrefix: String(format: "%02d", index + 1))
        }
    }

    /** Exports one page without a document order prefix. */
    public static func exportPage(_ page: MyDocumentPageDraft) -> MyDocumentExportFile {
        exportFile(for: page, orderPrefix: nil)
    }

    /** Returns Android's content type inferred from a selected filename. */
    public static func contentType(forFileName fileName: String) -> MyDocumentContentType {
        let lowercased = fileName.lowercased()
        return lowercased.hasSuffix(".html") || lowercased.hasSuffix(".htm") ? .html : .markdown
    }

    /**
     Sanitizes page titles using Android's export rule.

     Only ASCII letters, digits, period, underscore, hyphen, and space survive; the result is
     capped at 50 characters and falls back to `page` when empty.
     */
    public static func sanitizedExportTitle(_ title: String) -> String {
        let scalars = title.unicodeScalars.filter { scalar in
            (scalar.value >= 48 && scalar.value <= 57)
                || (scalar.value >= 65 && scalar.value <= 90)
                || (scalar.value >= 97 && scalar.value <= 122)
                || scalar == "."
                || scalar == "_"
                || scalar == "-"
                || scalar == " "
        }
        let sanitized = String(String.UnicodeScalarView(scalars.prefix(50)))
        return sanitized.isEmpty ? "page" : sanitized
    }

    private static func exportFile(
        for page: MyDocumentPageDraft,
        orderPrefix: String?
    ) -> MyDocumentExportFile {
        let isHTML = page.contentType == .html
        let fileExtension = isHTML ? "html" : "md"
        let mimeType = isHTML ? "text/html" : "text/markdown"
        let title = sanitizedExportTitle(page.title)
        let fileName = orderPrefix.map { "\($0)-\(title).\(fileExtension)" }
            ?? "\(title).\(fileExtension)"
        return MyDocumentExportFile(fileName: fileName, contentType: mimeType, content: page.content)
    }

    private static func deletingFinalPathExtension(_ fileName: String) -> String {
        let nsName = fileName as NSString
        let result = nsName.deletingPathExtension
        return result.isEmpty ? fileName : result
    }

    private static func pageOrder(_ lhs: MyDocumentPageDraft, _ rhs: MyDocumentPageDraft) -> Bool {
        if lhs.orderNumber != rhs.orderNumber { return lhs.orderNumber < rhs.orderNumber }
        if lhs.title != rhs.title {
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        return lhs.pageKey < rhs.pageKey
    }
}
